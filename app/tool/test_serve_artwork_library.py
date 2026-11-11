"""Disposable queue preservation, concurrency and HTTP boundary checks."""
import concurrent.futures
from functools import partial
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

import serve_artwork_library as server


def item(number=13, key="cable_row_triangle"):
    return {"number": number, "key": key, "revision": 1, "editions": {
        edition: {"sha256": character * 64, "illustration": 800 + index,
                  "source_sheet_sha256": "c" * 64, "source_cell": 1}
        for index, (edition, character) in enumerate((("male", "a"), ("female", "b")))}}


class QueueFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="alkion-regen-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.path = self.root / "queue.json"
        self.items = [item(), item(14, "dumbbell_row")]
        self.identities = {value["key"]: value["number"] for value in self.items}
        self.store = server.QueueStore(self.path, self.items, self.identities)

    def operation(self, number=13, edition="male", marked=True):
        current = next(value for value in self.items if value["number"] == number)
        return {"number": number, "edition": edition, "marked": marked,
                "selection": server.snapshot(current, edition)}


class QueueTests(QueueFixture):
    def test_independent_editions_idempotency_and_unmark(self):
        self.store.update(self.operation())
        first = self.path.read_bytes()
        self.store.update(self.operation())
        self.assertEqual(self.path.read_bytes(), first)
        self.store.update(self.operation(edition="female"))
        self.assertEqual(len(self.store.get()["entries"]), 2)
        self.store.update(self.operation(marked=False))
        self.assertEqual([entry["edition"] for entry in self.store.get()["entries"]], ["female"])

    def test_snapshot_survives_revision_and_retirement(self):
        self.store.update(self.operation())
        original = self.store.get()["entries"][0].copy()
        self.items[0]["revision"] = 2
        self.items[0]["editions"]["male"]["sha256"] = "d" * 64
        self.items[0]["editions"]["male"]["illustration"] = 9001
        self.store.update(self.operation())
        self.assertEqual(self.store.get()["entries"][0], original)
        retired_store = server.QueueStore(self.path, [self.items[1]], self.identities)
        retired_store.update(self.operation(14))
        self.assertEqual(retired_store.get()["entries"][0], original)
        with self.assertRaises(server.QueueError):
            retired_store.update(self.operation())

    def test_invalid_and_newer_files_preserved(self):
        valid = {"format": server.FORMAT, "entries": [server.snapshot(self.items[0], "male")]}
        unknown = json.loads(json.dumps(valid))
        unknown["entries"][0]["variant_key"] = "unknown"
        invalid_cell = json.loads(json.dumps(valid))
        invalid_cell["entries"][0]["source_cell"] = 99
        for value in (b"{corrupt", b'{"format":"future-v9","entries":[]}',
                      json.dumps(unknown).encode(), json.dumps(invalid_cell).encode(),
                      json.dumps({**valid, "extra": True}).encode(),
                      json.dumps({**valid, "entries": valid["entries"] * 2}).encode()):
            with self.subTest(value=value):
                self.path.write_bytes(value)
                with self.assertRaises(server.QueueError):
                    self.store.update(self.operation(14))
                self.assertEqual(self.path.read_bytes(), value)

    def test_rejects_stale_and_invalid_operations(self):
        stale = self.operation()
        stale["selection"]["sha256"] = "f" * 64
        for operation in (stale, {**self.operation(), "number": True},
                          {**self.operation(), "number": 9999},
                          {**self.operation(), "marked": "true"},
                          {**self.operation(), "path": "/tmp/forbidden"}):
            with self.assertRaises(server.QueueError):
                self.store.update(operation)
        self.assertFalse(self.path.exists())

    def test_two_store_instances_do_not_lose_updates(self):
        other = server.QueueStore(self.path, self.items, self.identities)
        operations = [(store, self.operation(number, edition)) for store, number in
                      ((self.store, 13), (other, 14)) for edition in ("male", "female")]
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            list(executor.map(lambda pair: pair[0].update(pair[1]), operations * 8))
        self.assertEqual(len(self.store.get()["entries"]), 4)

    def test_failed_replace_retains_file(self):
        self.store.update(self.operation())
        original = self.path.read_bytes()
        with patch.object(server.os, "replace", side_effect=OSError("disk failure")):
            with self.assertRaises(OSError):
                self.store.update(self.operation(14))
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["queue.json", "queue.json.lock"])


class HTTPTests(QueueFixture):
    def setUp(self):
        super().setUp()
        self.public = self.root / "public"
        self.public.mkdir()
        (self.public / "index.html").write_text("public viewer")
        (self.public / ".git").mkdir()
        (self.public / ".git/config").write_text("private")
        (self.public / "git-alias").symlink_to(self.public / ".git")
        (self.public / "escape").symlink_to(self.root)
        (self.root / "outside.html").write_text("private outside file")
        (self.public / "index-escape").mkdir()
        (self.public / "index-escape/index.html").symlink_to(self.root / "outside.html")
        self.http = ThreadingHTTPServer(("127.0.0.1", 0), partial(server.Handler, root=self.public, store=self.store))
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_http)
        self.origin = f"http://127.0.0.1:{self.http.server_port}"

    def close_http(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join()

    def request(self, method="GET", path=server.API, headers=None, body=None):
        connection = HTTPConnection("127.0.0.1", self.http.server_port)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, response.read(), dict(response.getheaders())
        finally:
            connection.close()

    def test_http_origin_type_and_fixed_path(self):
        encoded = json.dumps(self.operation())
        headers = {"Origin": self.origin, "Content-Type": "application/json"}
        self.assertEqual(self.request("POST", headers=headers, body=encoded)[0], 200)
        self.assertEqual(self.request("POST", headers={**headers, "Origin": "http://evil.test"}, body=encoded)[0], 403)
        self.assertEqual(self.request("POST", headers={**headers, "Host": "evil.test"}, body=encoded)[0], 403)
        self.assertEqual(self.request("POST", headers={"Content-Type": "application/json"}, body=encoded)[0], 403)
        self.assertEqual(self.request("POST", headers={**headers, "Content-Type": "text/plain"}, body=encoded)[0], 415)
        self.assertEqual(self.request("POST", path="/write", headers=headers, body=encoded)[0], 404)
        status, body, result_headers = self.request()
        self.assertEqual(status, 200)
        self.assertEqual(len(json.loads(body)["entries"]), 1)
        self.assertEqual(result_headers["Cache-Control"], "no-store")
        self.assertNotIn("Access-Control-Allow-Origin", result_headers)

    def test_static_files_cannot_escape_or_list(self):
        self.assertEqual(self.request(path="/")[0], 200)
        for path in ("/.git/config", "/%2egit/config", "/git-alias/config", "/escape/queue.json", "/escape/", "/index-escape/", "/../queue.json"):
            self.assertEqual(self.request(path=path)[0], 404)

    def test_review_files_revalidate_for_get_head_and_not_modified(self):
        review = self.public / "tools/artwork-library"
        review.mkdir(parents=True)
        for name in ("index.html", "data.js", "library.js", "library.css"):
            (review / name).write_text("synthetic public review file")
            path = "/tools/artwork-library/" + name
            for method in ("GET", "HEAD"):
                status, body, headers = self.request(method, path=path + "?v=synthetic")
                self.assertEqual(status, 200)
                self.assertEqual(headers["Cache-Control"], "no-cache")
                self.assertEqual(body, b"" if method == "HEAD" else b"synthetic public review file")
            status, body, headers = self.request(path=path, headers={"If-Modified-Since": headers["Last-Modified"]})
            self.assertEqual(status, 304)
            self.assertEqual(headers["Cache-Control"], "no-cache")
        self.assertEqual(self.request(path="/tools/artwork-library/")[2]["Cache-Control"], "no-cache")
        # Query versions select the same file and retain the existing path guard.
        image = self.public / "image.webp"
        image.write_bytes(b"synthetic selected image")
        self.assertEqual(self.request(path="/image.webp?v=" + "a" * 64)[:2], (200, image.read_bytes()))
        self.assertEqual(self.request(path="/escape/queue.json?v=version")[0], 404)
        self.assertEqual(self.request()[2]["Cache-Control"], "no-store")

    def test_corrupt_queue_get_and_post_return_error_preserving_bytes(self):
        self.path.write_bytes(b"{broken")
        self.assertEqual(self.request()[0], 409)
        self.assertEqual(self.request("POST", headers={"Origin": self.origin, "Content-Type": "application/json"}, body=json.dumps(self.operation()))[0], 409)
        self.assertEqual(self.path.read_bytes(), b"{broken")


if __name__ == "__main__":
    unittest.main()
