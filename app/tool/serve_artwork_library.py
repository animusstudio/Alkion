#!/usr/bin/env python3
"""Serve the public review library on loopback and persist an explicit regen queue.

Usage: python3 app/tool/serve_artwork_library.py --queue /path/to/queue.json --port 8766
No queue path is accepted through HTTP. No image generation is performed.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import tempfile
import threading
from urllib.parse import unquote, urlsplit

import prepare_artwork_library as library

FORMAT = "alkion-artwork-regeneration-v1"
API = "/api/regeneration"
FIELDS = {"number", "variant_key", "edition", "revision", "sha256", "illustration",
          "source_sheet_sha256", "source_cell"}


class QueueError(ValueError):
    pass


def snapshot(item: dict, edition: str) -> dict:
    image = item["editions"][edition]
    return {"number": item["number"], "variant_key": item["key"], "edition": edition,
            "revision": item["revision"], **{field: image[field] for field in
            ("sha256", "illustration", "source_sheet_sha256", "source_cell")}}


class QueueStore:
    def __init__(self, path: Path, items: list[dict], identities: dict[str, int]):
        self.path = path
        self.items = {item["number"]: item for item in items}
        self.identities = identities
        self.lock = threading.Lock()

    @contextmanager
    def locked(self):
        # Stable sidecar lock also serializes separate helper processes.
        with self.lock:
            with self.path.with_name(self.path.name + ".lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                yield

    def validate(self, value: dict) -> dict:
        if not isinstance(value, dict) or set(value) != {"format", "entries"} or value.get("format") != FORMAT or not isinstance(value.get("entries"), list):
            raise QueueError("Unknown or invalid queue format; existing file was preserved.")
        seen = set()
        for entry in value["entries"]:
            if not isinstance(entry, dict) or set(entry) != FIELDS:
                raise QueueError("Invalid queue entry; existing file was preserved.")
            if (type(entry["number"]) is not int or
                    not isinstance(entry["variant_key"], str) or
                    self.identities.get(entry["variant_key"]) != entry["number"] or
                    entry["edition"] not in ("male", "female") or
                    any(type(entry[field]) is not int or entry[field] < 1 for field in ("revision", "illustration", "source_cell")) or
                    entry["source_cell"] > 4 or
                    any(not isinstance(entry[field], str) or not re.fullmatch(r"[0-9a-f]{64}", entry[field]) for field in ("sha256", "source_sheet_sha256"))):
                raise QueueError("Invalid queue identity or provenance; existing file was preserved.")
            identity = (entry["number"], entry["edition"])
            if identity in seen:
                raise QueueError("Duplicate queue identity; existing file was preserved.")
            seen.add(identity)
        return value

    def read(self) -> dict:
        try:
            return self.validate(json.loads(self.path.read_text(encoding="utf-8")))
        except FileNotFoundError:
            return {"format": FORMAT, "entries": []}
        except (UnicodeError, json.JSONDecodeError) as error:
            raise QueueError("Unreadable queue JSON; existing file was preserved.") from error

    def get(self) -> dict:
        with self.locked():
            return self.read()

    def update(self, operation: dict) -> dict:
        if not isinstance(operation, dict) or set(operation) != {"number", "edition", "marked", "selection"}:
            raise QueueError("Expected number, edition, marked and selection.")
        number, edition, marked = operation["number"], operation["edition"], operation["marked"]
        if type(number) is not int or edition not in ("male", "female") or type(marked) is not bool:
            raise QueueError("Invalid regeneration operation.")
        item = self.items.get(number)
        if not item or not item["editions"].get(edition):
            raise QueueError("This current library selection is unavailable; reload the library.")
        expected = snapshot(item, edition)
        if operation["selection"] != expected:
            raise QueueError("Artwork selection changed; reload before marking it.")
        with self.locked():
            queue = self.read()
            identity = (number, edition)
            existing = next((entry for entry in queue["entries"] if (entry["number"], entry["edition"]) == identity), None)
            # Repeated desired-state writes retain the provenance originally marked.
            if marked and existing is None:
                queue["entries"].append(expected)
            elif not marked and existing is not None:
                queue["entries"].remove(existing)
            else:
                return queue
            queue["entries"].sort(key=lambda entry: (entry["number"], entry["edition"]))
            self.write(queue)
            return queue

    def write(self, queue: dict):
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=self.path.parent,
                                             prefix="." + self.path.name + ".", delete=False) as stream:
                temporary = Path(stream.name)
                json.dump(queue, stream, indent=2, ensure_ascii=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
            temporary = None
            directory = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, root: Path, store: QueueStore, **kwargs):
        self.root, self.store = root.resolve(), store
        super().__init__(*args, directory=str(root), **kwargs)

    def origin(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def end_headers(self):
        # Revalidate the review entry point and metadata after local updates.
        # Artwork itself has a content-versioned URL; queue responses keep no-store.
        path = urlsplit(self.path).path
        base = "/tools/artwork-library/"
        if path in {base.rstrip("/"), base, *(base + name for name in
                    ("index.html", "data.js", "library.js", "library.css"))}:
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def trusted(self, write=False):
        if self.headers.get("Host") != self.origin()[7:]:
            return False
        origin = self.headers.get("Origin")
        return (origin == self.origin() if write else origin in (None, self.origin())) and self.headers.get("Sec-Fetch-Site") in (None, "same-origin", "none")

    def respond(self, status, value):
        content = json.dumps(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self):
        if not self.trusted():
            return self.respond(403, {"error": "Same-origin loopback requests only."})
        if urlsplit(self.path).path == API:
            try:
                return self.respond(200, self.store.get())
            except (QueueError, OSError) as error:
                return self.respond(409, {"error": str(error)})
        return super().do_GET()

    def do_HEAD(self):
        if not self.trusted():
            self.send_error(403)
            return
        super().do_HEAD()

    def send_head(self):
        parts = Path(unquote(urlsplit(self.path).path)).parts
        target = Path(self.translate_path(self.path)).resolve()
        if target.is_dir():
            target = (target / "index.html").resolve()
        # Never expose .git, private dot-directories, symlink escapes or listings.
        if (any(part.startswith(".") for part in parts) or
                not target.is_relative_to(self.root) or
                any(part.startswith(".") for part in target.relative_to(self.root).parts) or
                target == self.store.path.resolve() or
                not target.is_file()):
            self.send_error(404)
            return None
        return super().send_head()

    def do_POST(self):
        if urlsplit(self.path).path != API:
            return self.respond(404, {"error": "Unknown endpoint."})
        if not self.trusted(write=True):
            return self.respond(403, {"error": "Same-origin loopback requests only."})
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
            return self.respond(415, {"error": "Content-Type must be application/json."})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 4096:
                raise QueueError("Invalid request size.")
            operation = json.loads(self.rfile.read(length))
            return self.respond(200, self.store.update(operation))
        except (ValueError, UnicodeError, TypeError, OSError) as error:
            return self.respond(409, {"error": str(error)})


def create_server(queue: Path, port: int) -> ThreadingHTTPServer:
    read = lambda path: json.loads(path.read_text(encoding="utf-8"))
    assets = library.APP / "assets"
    registry = read(assets / "exercise_artwork/library-numbers.json")
    data = library.build_data(read(assets / "catalog_trial/catalog.dev.json"), registry,
                              {edition: read(assets / "exercise_artwork" / name) for edition, name in
                               (("male", "manifest.json"), ("female", "female-manifest.json"))}, library.APP,
                              read(library.ROOT / "tools/artwork-library/latest-regeneration.json"))
    queue = queue.resolve()
    if queue.is_relative_to(library.ROOT.resolve()):
        raise QueueError("Choose a queue path outside the public repository.")
    if not queue.parent.is_dir():
        raise QueueError("Queue parent directory must already exist.")
    store = QueueStore(queue, data["items"], library.artwork.validate_registry(registry))
    with store.locked():
        if not queue.exists():
            store.write({"format": FORMAT, "entries": []})
    return ThreadingHTTPServer(("127.0.0.1", port), partial(Handler, root=library.ROOT, store=store))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--queue", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8766)
    args = parser.parse_args()
    server = create_server(args.queue, args.port)
    print(f"Artwork library: http://127.0.0.1:{server.server_port}/tools/artwork-library/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
