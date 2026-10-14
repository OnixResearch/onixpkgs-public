"""Expose the shared Laya decision API through one offline native Vulkan worker."""

import argparse
import importlib.util
import json
import math
import os
import selectors
import signal
import subprocess
import sys
import time
from pathlib import Path
from types import FrameType
from typing import Never
from wsgiref.simple_server import make_server
from wsgiref.types import StartResponse, WSGIEnvironment

# Load only the standard-library API module, even under Python isolated mode.
spec = importlib.util.spec_from_file_location(
    "laya_api", Path(__file__).with_name("laya_api.py")
)
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)

REVISION = "1c5edc17a7acd8701df6fc341c0d179f1c62c982"
RUNTIME_REVISION = "3ca6a325f9b357da518f8030ad6edece3c80146a"
MAX_OUTPUT = 512 * 1024
MAX_DIAGNOSTICS = 256 * 1024
STARTUP_TIMEOUT = 600
PREDICT_TIMEOUT = 80


def prepare(state: Path, revision: str) -> Path:
    if revision != REVISION:
        msg = "This package contains only the pinned English checkpoint"
        raise ValueError(msg)
    directory = Path(os.environ["LAYA_CPP_MODEL"])
    manifest = json.loads((directory / "model-manifest.json").read_text())
    if manifest["repo"] != api.MODEL or manifest["revision"] != revision:
        msg = "Packaged model provenance does not match the requested checkpoint"
        raise ValueError(msg)
    for file in manifest["files"]:
        if (directory / file["path"]).stat().st_size != file["bytes"]:
            msg = "Packaged checkpoint is incomplete"
            raise ValueError(msg)
    # Assets remain immutable in the fixed-output Nix closure; no runtime download.
    state.mkdir(parents=True, exist_ok=True)
    return directory


class Worker:
    def __init__(self, directory: Path, threads: int) -> None:
        self.backend = None
        self.device_name = None
        environment = dict(os.environ, OMP_NUM_THREADS=str(threads))
        self.process = subprocess.Popen(
            [
                os.environ["LAYA_CPP_CLI"],
                "--model",
                str(directory),
                "--variant",
                "english",
                "--vulkan",
                "--tensor-core-fp32",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            env=environment,
        )
        try:
            for stream in (
                self.process.stdin,
                self.process.stdout,
                self.process.stderr,
            ):
                os.set_blocking(stream.fileno(), False)
            self.predict(
                "The service is starting.",
                {"ready": {"type": "noul", "instructions": "Is the service starting?"}},
                timeout=STARTUP_TIMEOUT,
            )
        except BaseException:
            self.close()
            raise

    def check(self) -> None:
        if self.process.poll() is not None:
            msg = "Native Laya worker exited; refusing to serve stale readiness"
            raise SystemExit(msg)

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()

    def exchange(self, request: bytes, timeout: int) -> bytes:
        self.check()
        deadline = time.monotonic() + timeout
        output = bytearray()
        diagnostics = 0
        pending = memoryview(request)
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdin, selectors.EVENT_WRITE)
            selector.register(self.process.stdout, selectors.EVENT_READ)
            selector.register(self.process.stderr, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    msg = "Native Laya worker timed out"
                    raise RuntimeError(msg)
                events = selector.select(remaining)
                if not events:
                    msg = "Native Laya worker timed out"
                    raise RuntimeError(msg)
                for key, _ in events:
                    if key.fileobj is self.process.stdin:
                        written = os.write(key.fd, pending)
                        pending = pending[written:]
                        if not pending:
                            selector.unregister(key.fileobj)
                        continue
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        if key.fileobj is self.process.stdout:
                            msg = "Native Laya worker closed its output"
                            raise RuntimeError(msg)
                        selector.unregister(key.fileobj)
                        continue
                    if key.fileobj is self.process.stderr:
                        diagnostics += len(chunk)
                        if diagnostics > MAX_DIAGNOSTICS:
                            msg = "Native Laya worker exceeded the diagnostic limit"
                            raise RuntimeError(msg)
                        sys.stderr.buffer.write(chunk)
                        sys.stderr.buffer.flush()
                    else:
                        output.extend(chunk)
                        if len(output) > MAX_OUTPUT:
                            msg = "Native Laya worker exceeded the output limit"
                            raise RuntimeError(msg)
                if b"\n" in output:
                    if (
                        not output.endswith(b"\n")
                        or output.count(b"\n") != 1
                        or pending
                    ):
                        msg = "Native Laya worker violated the JSON-lines protocol"
                        raise RuntimeError(msg)
                    self.check()
                    return bytes(output)

    def predict(
        self,
        state: str | dict[str, object],
        questions: dict[str, dict[str, object]],
        timeout: int = PREDICT_TIMEOUT,
    ) -> dict[str, object]:
        try:
            request = (
                json.dumps(
                    {"state": state, "questions": questions},
                    ensure_ascii=False,
                    allow_nan=False,
                ).encode()
                + b"\n"
            )
            envelope = json.loads(self.exchange(request, timeout))
            if not isinstance(envelope, dict) or "error" in envelope:
                msg = f"Native Laya inference failed: {envelope}"
                raise RuntimeError(msg)
            backend, device = envelope["backend"], envelope["device"]
            # The packaged native guard checks the physical Vulkan device type;
            # the live response independently verifies the selected backend.
            if not isinstance(backend, str) or not backend.startswith("Vulkan"):
                msg = "Native Laya worker did not use Vulkan"
                raise RuntimeError(msg)
            if not isinstance(device, str) or not device:
                msg = "Native Laya worker did not identify its GPU"
                raise RuntimeError(msg)
            if self.backend is not None and (backend, device) != (
                self.backend,
                self.device_name,
            ):
                msg = "Native Laya worker identity changed"
                raise RuntimeError(msg)
            results = envelope["results"]
            if not isinstance(results, list) or len(results) != 1:
                msg = "Native Laya worker returned an invalid result envelope"
                raise RuntimeError(msg)
            result = results[0]
            if not isinstance(result, dict) or set(result["answers"]) != set(questions):
                msg = "Native Laya worker returned mismatched answers"
                raise RuntimeError(msg)
            self.check_values(result)
            for name, question in questions.items():
                if result["answers"][name]["type"] != question["type"]:
                    msg = "Native Laya worker returned a mismatched answer type"
                    raise RuntimeError(msg)
            elapsed = envelope["elapsed_ms"]
            if (
                type(elapsed) not in (int, float)
                or not math.isfinite(elapsed)
                or elapsed < 0
            ):
                msg = "Native Laya worker returned invalid timing"
                raise RuntimeError(msg)
            self.backend, self.device_name = backend, device
            return {**result, "elapsed_ms": elapsed}
        except Exception as error:
            # SystemExit bypasses the shared API's recoverable 503 handler. A
            # corrupt, dead or stalled resident worker requires systemd restart.
            msg = f"Fatal native Laya worker failure: {error}"
            raise SystemExit(msg) from error

    @staticmethod
    def check_values(value: object) -> None:
        if value is None or (isinstance(value, float) and not math.isfinite(value)):
            msg = "Native Laya worker returned a nonfinite or null value"
            raise RuntimeError(msg)
        if isinstance(value, dict):
            for item in value.values():
                Worker.check_values(item)
        elif isinstance(value, list):
            for item in value:
                Worker.check_values(item)


class Decisions(api.Decisions):
    def __init__(self, worker: Worker, directory: Path) -> None:
        # Reuse Decisions.__call__ and validate without invoking its Torch loader.
        self.agent = worker
        config = json.loads((directory / "rl_agent_config.json").read_text())
        provenance = json.loads(Path(os.environ["LAYA_CPP_PROVENANCE"]).read_text())
        self.identity = {
            "model": api.MODEL,
            "revision": REVISION,
            "runtime": "laya.cpp",
            "runtime_revision": RUNTIME_REVISION,
            "runtime_patches": provenance["patches"],
            "device": "vulkan",
            "dtype": "float32",
            "precision": "compensated-fp32",
            "backend": worker.backend,
            "device_name": worker.device_name,
            "language": "English",
            "max_tokens_per_question": config.get("max_len", 512),
            "head_max_tokens": config.get("head_max_len", 192),
            "limitations": [
                "Long state, instructions and options can be truncated by the checkpoint's token budgets.",
                "Base checkpoint probabilities are not domain-calibrated; do not treat confidence as a safety guarantee.",
                "The base checkpoint is not the separately fine-tuned typed-decisions checkpoint.",
            ],
        }

    def __call__(
        self, env: WSGIEnvironment, start_response: StartResponse
    ) -> list[bytes]:
        self.agent.check()
        return super().__call__(env, start_response)


def stop(signum: int, frame: FrameType | None) -> Never:
    raise SystemExit(0)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "serve"))
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=7999)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    if args.revision != REVISION or not 1 <= args.threads <= 16:
        parser.error("Use the packaged immutable English revision and 1-16 CPU threads")
    if os.environ["LAYA_CPP_RUNTIME_REVISION"] != RUNTIME_REVISION:
        parser.error("Native runtime provenance mismatch")
    directory = prepare(args.state_dir, args.revision)
    if args.command == "prepare":
        print(
            json.dumps(
                {"prepared": str(directory), "model": api.MODEL, "revision": REVISION}
            ),
            flush=True,
        )
        return
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    worker = Worker(directory, args.threads)
    try:
        decisions = Decisions(worker, directory)
        # Single-threaded HTTP and a single pipe pair serialize all inference.
        with make_server(
            args.host, args.port, decisions, server_class=api.BoundedServer
        ) as server:
            server.timeout = 1
            print(
                json.dumps(
                    {
                        "status": "listening",
                        "host": args.host,
                        "port": args.port,
                        **decisions.identity,
                    }
                ),
                flush=True,
            )
            while True:
                worker.check()
                server.handle_request()
    finally:
        worker.close()


if __name__ == "__main__":
    main()
