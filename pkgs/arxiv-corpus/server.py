"""Private, read-only access to a pinned arXiv Complete snapshot."""

import argparse
import fcntl
import functools
import hashlib
import json
import os
import re
import sqlite3
import time
import traceback
from pathlib import Path
from socket import socket
from typing import BinaryIO, TypedDict
from wsgiref.simple_server import WSGIServer, make_server
from wsgiref.types import StartResponse, WSGIEnvironment

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq
from huggingface_hub import HfApi, HfFileSystem, hf_hub_download

DATASET = "secemp9/arxiv-complete"
SCHEMA_VERSION = 1
MAX_GROUP_BYTES = 128 * 1024 * 1024
MAX_REQUEST_BYTES = 16 * 1024
PAPER_ID = re.compile(r"(?:[0-9]{4}\.[0-9]{4,5}|[a-z-]+(?:\.[A-Z]{2})?/[0-9]{7})\Z")


class Snapshot(TypedDict):
    dataset: str
    revision: str
    schema_version: int
    papers: int
    papers_with_text: int
    metadata_harvested: str
    file_mirror_taken: str
    source_version: str
    live_arxiv: bool


class PaperText(TypedDict):
    text: str
    text_sha256: str
    main_file: str | None
    resolution: str | None
    text_encoding: str | None
    shard: str


class RequestError(Exception):
    def __init__(self, status: str, message: str) -> None:
        self.status = status
        super().__init__(message)


def integer(value: object, name: str, low: int, high: int) -> int:
    if type(value) is not int or not low <= value <= high:
        error_status = "400 Bad Request"
        message = f"{name} must be an integer between {low} and {high}"
        raise RequestError(error_status, message)
    return value


def encode(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, default=str)


def open_database(path: Path) -> sqlite3.Connection:
    db = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA cache_size=-32768")
    return db


def identity(db: sqlite3.Connection) -> Snapshot:
    return json.loads(
        db.execute("SELECT value FROM info WHERE key='snapshot'").fetchone()[0]
    )


def remote_file(fs: HfFileSystem, revision: str, path: str) -> BinaryIO:
    return fs.open(
        f"datasets/{DATASET}@{revision}/{path}",
        "rb",
        block_size=65536,
        cache_type="blockcache",
    )


def prepare(state: Path, revision: str) -> None:
    # r[impl onix.arxiv-corpus.search]
    state.mkdir(parents=True, exist_ok=True)
    with (state / "prepare.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        destination = state / "corpus.sqlite"
        if destination.exists():
            with open_database(destination) as current:
                existing = identity(current)
            if (
                existing["revision"] == revision
                and existing["schema_version"] == SCHEMA_VERSION
            ):
                print(encode(existing), flush=True)
                return
        temporary = state / "corpus.building.sqlite"
        temporary.unlink(missing_ok=True)
        db = sqlite3.connect(temporary)
        db.executescript("""
            PRAGMA journal_mode=DELETE;
            PRAGMA cache_size=-65536;
            PRAGMA temp_store=FILE;
            CREATE TABLE papers (paper_id TEXT PRIMARY KEY, title TEXT, abstract TEXT,
                                 authors TEXT, category TEXT, metadata TEXT NOT NULL);
            CREATE TABLE text_groups (path TEXT, row_group INTEGER, first_id TEXT,
                                      last_id TEXT, bytes INTEGER);
            CREATE TABLE info (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
        api = HfApi(token=False)
        files = sorted(
            item.path
            for item in api.list_repo_tree(
                DATASET, "metadata", repo_type="dataset", revision=revision
            )
            if item.path.endswith(".parquet")
        )
        if not files:
            message = "The pinned snapshot has no metadata shards"
            raise RuntimeError(message)
        expected = count = 0
        for path in files:
            local = hf_hub_download(
                DATASET,
                path,
                repo_type="dataset",
                revision=revision,
                cache_dir=state / "hub",
                token=False,
            )
            parquet = pq.ParquetFile(local)
            expected += parquet.metadata.num_rows
            for batch in parquet.iter_batches(batch_size=2000, use_threads=False):
                rows = []
                for paper in batch.to_pylist():
                    pid, title, abstract, authors = (
                        paper.pop(key)
                        for key in ("paper_id", "title", "abstract", "authors")
                    )
                    rows.append(
                        (
                            pid,
                            title,
                            abstract,
                            authors,
                            paper["primary_category"],
                            encode(paper),
                        )
                    )
                db.executemany("INSERT INTO papers VALUES (?, ?, ?, ?, ?, ?)", rows)
                count += len(rows)
            db.commit()
            print(
                encode({"phase": "metadata", "shard": path, "papers": count}),
                flush=True,
            )
        if count != expected or count == 0:
            message = "Metadata import does not match the complete shard row counts"
            raise RuntimeError(message)
        print(encode({"phase": "full_text_index", "papers": count}), flush=True)
        db.executescript("""
            CREATE INDEX category_idx ON papers(category);
            CREATE VIRTUAL TABLE papers_fts USING fts5(title, abstract, authors,
                content='papers', content_rowid='rowid', tokenize='porter unicode61');
            INSERT INTO papers_fts(papers_fts) VALUES ('rebuild');
        """)
        fs = HfFileSystem(token=False)
        text_files = sorted(
            item.path
            for item in api.list_repo_tree(
                DATASET, "paper_text", repo_type="dataset", revision=revision
            )
            if item.path.endswith(".parquet")
        )
        if not text_files:
            message = "The pinned snapshot has no paper_text shards"
            raise RuntimeError(message)
        text_count = 0
        previous = None
        for path in text_files:
            with remote_file(fs, revision, path) as stream:
                parquet = pq.ParquetFile(stream)
                column = parquet.schema_arrow.get_field_index("paper_id")
                if column < 0:
                    message = f"No paper_id column in {path}"
                    raise RuntimeError(message)
                for number in range(parquet.metadata.num_row_groups):
                    group = parquet.metadata.row_group(number)
                    stats = group.column(column).statistics
                    if stats is None or not stats.has_min_max:
                        message = f"Missing paper_id range statistics in {path}"
                        raise RuntimeError(message)
                    if previous is not None and stats.min <= previous:
                        message = "paper_text ranges overlap or are not sorted"
                        raise RuntimeError(message)
                    if group.total_byte_size > MAX_GROUP_BYTES:
                        message = (
                            "paper_text row group exceeds the supported memory bound"
                        )
                        raise RuntimeError(message)
                    db.execute(
                        "INSERT INTO text_groups VALUES (?, ?, ?, ?, ?)",
                        (path, number, stats.min, stats.max, group.total_byte_size),
                    )
                    previous = stats.max
                    text_count += group.num_rows
            db.commit()
            print(
                encode({"phase": "text_ranges", "shard": path, "papers": text_count}),
                flush=True,
            )
        snapshot = {
            "dataset": DATASET,
            "revision": revision,
            "schema_version": SCHEMA_VERSION,
            "papers": count,
            "papers_with_text": text_count,
            "metadata_harvested": "2026-08-30",
            "file_mirror_taken": "2026-09-05",
            "source_version": "unversioned",
            "live_arxiv": False,
        }
        db.execute("INSERT INTO info VALUES ('snapshot', ?)", (encode(snapshot),))
        db.commit()
        db.close()
        with temporary.open("rb") as stream:
            os.fsync(stream.fileno())
        temporary.replace(destination)
        directory = os.open(state, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        print(encode({"phase": "ready", **snapshot}), flush=True)


class Corpus:
    def __init__(self, state: Path) -> None:
        self.db = open_database(state / "corpus.sqlite")
        self.snapshot = identity(self.db)
        if self.snapshot["schema_version"] != SCHEMA_VERSION:
            message = "Run prepare for the current corpus schema"
            raise RuntimeError(message)
        self.fs = HfFileSystem(token=False)
        self.text = functools.lru_cache(maxsize=4)(self._read_text)

    def search(self, request: dict[str, object]) -> dict[str, object]:
        query = request.get("query")
        if not isinstance(query, str) or not query.strip() or len(query) > 500:
            error_status = "400 Bad Request"
            message = "query must contain 1-500 characters of SQLite FTS5 search syntax"
            raise RequestError(error_status, message)
        limit = integer(request.get("limit", 10), "limit", 1, 20)
        category = request.get("category")
        if category is not None and (
            not isinstance(category, str) or len(category) > 64
        ):
            error_status = "400 Bad Request"
            message = "category must be a primary-category string"
            raise RequestError(error_status, message)
        sql = """SELECT p.*, snippet(papers_fts, 1, '', '', ' … ', 40) AS snippet,
                        bm25(papers_fts, 8.0, 1.0, 2.0) AS rank
                 FROM papers_fts JOIN papers p ON p.rowid=papers_fts.rowid
                 WHERE papers_fts MATCH ?"""
        args: list[str | int] = [query]
        if category is not None:
            sql += " AND p.category=?"
            args.append(category)
        sql += " ORDER BY rank LIMIT ?"
        args.append(limit)
        deadline = time.monotonic() + 10
        self.db.set_progress_handler(lambda: time.monotonic() > deadline, 10000)
        try:
            rows = self.db.execute(sql, args).fetchall()
        except sqlite3.OperationalError as error:
            if str(error) == "interrupted":
                error_status = "504 Gateway Timeout"
                message = "Search exceeded 10 seconds; narrow the query"
                raise RequestError(error_status, message) from error
            error_status = "400 Bad Request"
            message = f"Invalid FTS5 query: {error}"
            raise RequestError(error_status, message) from error
        finally:
            self.db.set_progress_handler(None, 0)
        results = []
        for row in rows:
            metadata = json.loads(row["metadata"])
            results.append(
                {
                    "paper_id": row["paper_id"],
                    "title": row["title"],
                    "authors": (row["authors"] or "")[:600],
                    "snippet": row["snippet"],
                    "primary_category": row["category"],
                    "rank": row["rank"],
                    **{
                        key: metadata.get(key)
                        for key in (
                            "license",
                            "first_version_date",
                            "latest_version_date",
                            "arxiv_abs_url",
                        )
                    },
                }
            )
        return {
            **self.snapshot,
            "results": results,
            "query_syntax": "SQLite FTS5; category matches primary_category",
        }

    def _read_text(self, paper_id: str) -> PaperText | None:
        # r[impl onix.arxiv-corpus.read]
        group = self.db.execute(
            "SELECT * FROM text_groups WHERE first_id<=? AND last_id>=?",
            (paper_id, paper_id),
        ).fetchone()
        if group is None:
            return None
        with remote_file(self.fs, self.snapshot["revision"], group["path"]) as stream:
            table = pq.ParquetFile(stream).read_row_group(
                group["row_group"], use_threads=False
            )
            matches = table.filter(pc.equal(table["paper_id"], paper_id)).to_pylist()
        if not matches:
            return None
        if len(matches) != 1:
            message = "Duplicate paper_text rows"
            raise RuntimeError(message)
        paper = matches[0]
        if (
            hashlib.sha256(paper["text"].encode("utf-8")).hexdigest()
            != paper["text_sha256"]
        ):
            message = "Paper text digest does not match the published snapshot"
            raise RuntimeError(message)
        paper["shard"] = group["path"]
        return paper

    def paper(self, request: dict[str, object]) -> dict[str, object]:
        pid = request.get("paper_id")
        if not isinstance(pid, str) or PAPER_ID.fullmatch(pid) is None:
            error_status = "400 Bad Request"
            message = "Use a bare modern or legacy arXiv ID, without a version suffix; corpus source text is unversioned"
            raise RequestError(error_status, message)
        offset = integer(request.get("offset", 0), "offset", 0, 2**31 - 1)
        length = integer(request.get("length", 12000), "length", 1, 20000)
        row = self.db.execute(
            "SELECT * FROM papers WHERE paper_id=?", (pid,)
        ).fetchone()
        if row is None:
            error_status = "404 Not Found"
            message = "Paper is absent from this snapshot"
            raise RequestError(error_status, message)
        metadata = {
            **json.loads(row["metadata"]),
            **{key: row[key] for key in ("paper_id", "title", "abstract", "authors")},
        }
        content = self.text(pid)
        if content is None:
            return {
                **self.snapshot,
                "metadata": metadata,
                "text_available": False,
                "reason": "This snapshot has metadata but no assembled paper_text for this paper",
            }
        text = content["text"]
        if offset > len(text):
            error_status = "400 Bad Request"
            message = "offset exceeds the paper's total_chars"
            raise RequestError(error_status, message)
        end = min(offset + length, len(text))
        return {
            **self.snapshot,
            "metadata": metadata,
            "text_available": True,
            "text": text[offset:end],
            "offset": offset,
            "total_chars": len(text),
            "next_offset": end if end < len(text) else None,
            **{
                key: content[key]
                for key in (
                    "text_sha256",
                    "main_file",
                    "resolution",
                    "text_encoding",
                    "shard",
                )
            },
            "text_format": "LaTeX source, not rendered prose; may include comments or withdrawal stubs",
        }

    def __call__(
        self, env: WSGIEnvironment, start_response: StartResponse
    ) -> list[bytes]:
        status = "200 OK"
        try:
            route = (env["REQUEST_METHOD"], env["PATH_INFO"])
            if route == ("GET", "/health"):
                result = {"status": "ready", **self.snapshot}
            elif route in (("POST", "/search"), ("POST", "/paper")):
                if env.get("CONTENT_TYPE", "").split(";")[0] != "application/json":
                    error_status = "415 Unsupported Media Type"
                    message = "Use application/json"
                    raise RequestError(error_status, message)
                size = int(env.get("CONTENT_LENGTH") or "0")
                if not 0 < size <= MAX_REQUEST_BYTES:
                    error_status = "413 Content Too Large"
                    message = "Request body must contain 1-16384 bytes"
                    raise RequestError(error_status, message)
                request = json.loads(env["wsgi.input"].read(size))
                if not isinstance(request, dict):
                    error_status = "400 Bad Request"
                    message = "JSON body must be an object"
                    raise RequestError(error_status, message)
                result = (
                    self.search(request)
                    if route[1] == "/search"
                    else self.paper(request)
                )
            else:
                error_status = "404 Not Found"
                message = "Unknown API route"
                raise RequestError(error_status, message)
        except RequestError as error:
            status, result = error.status, {"error": str(error)}
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as error:
            status, result = "400 Bad Request", {"error": str(error)}
        except Exception:
            traceback.print_exc()
            status, result = (
                "503 Service Unavailable",
                {
                    "error": "Corpus read failed; inspect the service journal. This is not a missing-paper result."
                },
            )
        body = encode(result).encode("utf-8")
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
    subcommands = parser.add_subparsers(dest="command", required=True)
    build = subcommands.add_parser("prepare")
    build.add_argument("--state-dir", type=Path, required=True)
    build.add_argument("--revision", required=True)
    serve = subcommands.add_parser("serve")
    serve.add_argument("--state-dir", type=Path, required=True)
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=7998)
    args = parser.parse_args()
    pa.set_cpu_count(2)
    pa.set_io_thread_count(2)
    if args.command == "prepare":
        if re.fullmatch(r"[a-f0-9]{40}", args.revision) is None:
            parser.error("revision must be an immutable 40-character commit")
        prepare(args.state_dir, args.revision)
    else:
        corpus = Corpus(args.state_dir)
        with make_server(
            args.host, args.port, corpus, server_class=BoundedServer
        ) as server:
            print(
                encode(
                    {
                        "status": "listening",
                        "host": args.host,
                        "port": args.port,
                        **corpus.snapshot,
                    }
                ),
                flush=True,
            )
            server.serve_forever()


if __name__ == "__main__":
    main()
