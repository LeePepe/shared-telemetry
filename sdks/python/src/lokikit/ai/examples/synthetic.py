"""Public API example: synthetic data and a private, ephemeral HTTP receiver."""
import http.server
import json
import logging
import queue
import threading

from lokikit import LokiClient, LokiHandler


def main():
    received = queue.Queue()

    class Receiver(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            received.put((self.path, self.headers.get("Authorization"), body))
            self.send_response(204 if self.headers.get("Authorization") == "Bearer synthetic-only" else 401)
            self.end_headers()

        def log_message(self, *_):
            pass

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Receiver) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        endpoint = f"http://127.0.0.1:{server.server_port}/loki/api/v1/push"
        client = LokiClient(endpoint=endpoint, labels={"app": "synthetic-test"},
                            token="synthetic-only", flush_interval=3600)
        rejected = LokiClient(endpoint=endpoint, labels={"app": "synthetic-test"},
                              token="synthetic-rejected", flush_interval=3600)
        handler = LokiHandler(endpoint=endpoint, labels={"app": "synthetic-handler"},
                              token="synthetic-only", flush_interval=3600)
        try:
            line = json.dumps({"event": "synthetic.completed", "duration_ms": 1})
            client.push(line)
            client.flush()
            path, auth, body = received.get(timeout=2)
            assert path == "/loki/api/v1/push" and auth == "Bearer synthetic-only"
            stream = body["streams"][0]
            assert stream["stream"] == {"app": "synthetic-test"}
            assert len(stream["values"]) == 1 and stream["values"][0][0].isdigit()
            assert stream["values"][0][1] == line and client.dropped_entries == 0

            rejected.push(line)
            rejected.flush()
            received.get(timeout=2)
            assert rejected.dropped_entries == 1

            handler.emit(logging.LogRecord("synthetic", logging.INFO, "fixture", 1,
                                           "synthetic.completed", (), None))
            handler.flush()
            _, _, body = received.get(timeout=2)
            assert body["streams"][0]["stream"] == {"app": "synthetic-handler"}
            assert json.loads(body["streams"][0]["values"][0][1])["message"] == "synthetic.completed"
            assert handler.client.dropped_entries == 0
            print("PYTHON_CONSUMER_OK")
        finally:
            handler.close()
            rejected.close()
            client.close()
            server.shutdown()
            thread.join(timeout=2)
            assert not thread.is_alive()


if __name__ == "__main__":
    main()
