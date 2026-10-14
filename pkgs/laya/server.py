"""Serve the English Laya checkpoint as typed decisions, not chat completions."""

import argparse
import fcntl
import importlib.metadata
import json
import os
import re
import shutil
import traceback
from pathlib import Path
from socket import socket
from wsgiref.simple_server import WSGIServer, make_server
from wsgiref.types import StartResponse, WSGIEnvironment

MODEL = "convaiinnovations/laya"
FILES = (
    "model.safetensors",
    "rl_agent_config.json",
    "encoder/config.json",
    "tokenizer/tokenizer.json",
    "tokenizer/tokenizer_config.json",
)
MAX_BODY = 32768


class RequestError(Exception):
    pass


def prepare(state: Path, revision: str) -> Path:
    from huggingface_hub import hf_hub_download
    from huggingface_hub.errors import LocalEntryNotFoundError

    state.mkdir(parents=True, exist_ok=True)
    directory = state / revision
    with (state / "prepare.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for name in FILES:
            kwargs = {
                "repo_id": MODEL,
                "filename": name,
                "revision": revision,
                "cache_dir": state / "hub",
                "token": False,
            }
            try:
                source = hf_hub_download(**kwargs, local_files_only=True)
            except LocalEntryNotFoundError:
                source = hf_hub_download(**kwargs)
            target = directory / name
            target.parent.mkdir(parents=True, exist_ok=True)
            # The SDK normalizes this config in place; never mutate the HF cache blob.
            if name == "tokenizer/tokenizer_config.json":
                shutil.copyfile(source, target)
            elif not target.exists():
                target.symlink_to(source)
    return directory


def validate(
    request: object,
) -> tuple[str | dict[str, object], dict[str, dict[str, object]]]:
    if not isinstance(request, dict) or not isinstance(
        request.get("state"), (str, dict)
    ):
        message = "state must be an English string or JSON object"
        raise RequestError(message)
    json.dumps(request["state"], allow_nan=False)
    questions = request.get("questions")
    if not isinstance(questions, dict) or not 1 <= len(questions) <= 8:
        message = "questions must contain 1-8 named questions"
        raise RequestError(message)
    for name, question in questions.items():
        if not name or len(name) > 64 or not isinstance(question, dict):
            message = "Question names must contain 1-64 characters and definitions must be objects"
            raise RequestError(message)
        kind = question.get("type")
        if kind not in ("choice", "score", "noul"):
            message = "Question type must be choice, score or noul"
            raise RequestError(message)
        instructions = question.get("instructions")
        if (
            not isinstance(instructions, str)
            or not instructions.strip()
            or len(instructions) > 1000
        ):
            message = "Question instructions must contain 1-1000 characters"
            raise RequestError(message)
        criteria = question.get("criteria")
        if kind == "noul" and criteria is None:
            continue
        if kind == "choice" and not isinstance(criteria, (dict, list)):
            message = (
                "choice criteria must be a label/description object or string array"
            )
            raise RequestError(message)
        if kind == "score" and not isinstance(criteria, list):
            message = "score criteria must be an ordered string array"
            raise RequestError(message)
        if kind == "noul" and (
            not isinstance(criteria, dict) or set(criteria) != {"false", "true"}
        ):
            message = "noul criteria, when supplied, must describe false and true"
            raise RequestError(message)
        if not 2 <= len(criteria) <= 20:
            message = "Use 2-20 criteria per question"
            raise RequestError(message)
        values = (
            list(criteria.keys()) + list(criteria.values())
            if isinstance(criteria, dict)
            else criteria
        )
        if any(
            not isinstance(value, str) or not value.strip() or len(value) > 500
            for value in values
        ):
            message = "Criterion labels and descriptions must be nonempty strings of at most 500 characters"
            raise RequestError(message)
        if isinstance(criteria, list) and len(set(criteria)) != len(criteria):
            message = "Criterion labels must be distinct"
            raise RequestError(message)
    return request["state"], questions


class Decisions:
    def __init__(self, directory: Path, revision: str, threads: int) -> None:
        # r[impl onix.laya.decisions]
        # All assets are local before importing the SDK; no remote-code fallback.
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        import laya
        import torch

        torch.set_num_threads(threads)
        torch.set_num_interop_threads(1)
        self.agent = laya.load(str(directory), device="cpu")
        self.identity = {
            "model": MODEL,
            "revision": revision,
            "sdk_version": importlib.metadata.version("laya"),
            "device": "cpu",
            "language": "English",
            "max_tokens_per_question": self.agent.cfg.get("max_len", 512),
            "head_max_tokens": self.agent.cfg.get("head_max_len", 192),
            "limitations": [
                "Long state, instructions and options can be truncated by the checkpoint's token budgets.",
                "Base checkpoint probabilities are not domain-calibrated; do not treat confidence as a safety guarantee.",
                "The base checkpoint is not the separately fine-tuned typed-decisions checkpoint.",
            ],
        }

    def __call__(
        self, env: WSGIEnvironment, start_response: StartResponse
    ) -> list[bytes]:
        status = "200 OK"
        try:
            route = (env["REQUEST_METHOD"], env["PATH_INFO"])
            if route == ("GET", "/health"):
                result = {"status": "ready", **self.identity}
            elif route == ("POST", "/predict"):
                if env.get("CONTENT_TYPE", "").split(";")[0] != "application/json":
                    message = "Use application/json"
                    raise RequestError(message)
                size = int(env.get("CONTENT_LENGTH") or "0")
                if not 0 < size <= MAX_BODY:
                    message = "Request body must contain 1-32768 bytes"
                    raise RequestError(message)
                state, questions = validate(json.loads(env["wsgi.input"].read(size)))
                result = {**self.agent.predict(state, questions), **self.identity}
            else:
                status, result = "404 Not Found", {"error": "Unknown API route"}
            body = json.dumps(result, ensure_ascii=False, allow_nan=False).encode(
                "utf-8"
            )
        except (
            RequestError,
            json.JSONDecodeError,
            UnicodeDecodeError,
            ValueError,
        ) as error:
            status = "400 Bad Request"
            body = json.dumps({"error": str(error)}).encode("utf-8")
        except Exception:
            traceback.print_exc()
            status = "503 Service Unavailable"
            body = b'{"error":"Laya inference failed; inspect the service journal"}'
        start_response(
            status,
            [
                ("Content-Type", "application/json; charset=utf-8"),
                ("Content-Length", str(len(body))),
            ],
        )
        return [body]


class BoundedServer(WSGIServer):
    def get_request(self) -> tuple[socket, tuple[str, int]]:
        connection, address = super().get_request()
        connection.settimeout(30)
        return connection, address


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "serve"))
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=7999)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    if (
        re.fullmatch(r"[a-f0-9]{40}", args.revision) is None
        or not 1 <= args.threads <= 16
    ):
        parser.error("Use an immutable 40-character revision and 1-16 CPU threads")
    os.environ["USE_TF"] = "0"
    directory = prepare(args.state_dir, args.revision)
    if args.command == "prepare":
        print(
            json.dumps(
                {"prepared": str(directory), "model": MODEL, "revision": args.revision}
            ),
            flush=True,
        )
        return
    decisions = Decisions(directory, args.revision, args.threads)
    with make_server(
        args.host, args.port, decisions, server_class=BoundedServer
    ) as server:
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
        server.serve_forever()


if __name__ == "__main__":
    main()
