#!/usr/bin/env python3
"""Local OpenAI-compatible transcription server for Parakeet Redux (moondream/parakeet-redux).

VoxOS's "Custom" transcription provider posts a multipart request to an OpenAI-style
/v1/audio/transcriptions endpoint. This serves that endpoint on localhost from a model that
stays loaded between requests, so the second dictation does not pay the load cost again.

Audio never leaves the machine: the server binds to 127.0.0.1 only, and the model runs locally
(the one network call is the first-run model download from Hugging Face).

    server.py [--port 8765] [--device cpu|mps|cuda] [--token SECRET]
"""
import argparse
import json
import os
import tempfile
import threading
from email.parser import BytesParser
from email.policy import HTTP
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_ID = "moondream/parakeet-redux"
MAX_BODY = 200 * 1024 * 1024  # 200 MB, far above any dictation clip


def parse_multipart(content_type: str, body: bytes) -> dict:
    """Returns {field name: (filename or None, bytes)} for a multipart/form-data body."""
    message = BytesParser(policy=HTTP).parsebytes(
        b"Content-Type: " + content_type.encode("latin-1") + b"\r\n\r\n" + body
    )
    fields = {}
    if not message.is_multipart():
        return fields
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name:
            fields[name] = (part.get_filename(), part.get_payload(decode=True) or b"")
    return fields


class Transcriber:
    """Keeps one model loaded and serialises requests, since the runtime is not reentrant."""

    def __init__(self, device):
        import moondream as md

        kwargs = {"device": device} if device else {}
        self._lock = threading.Lock()
        self._context = md.photon(MODEL_ID, **kwargs)
        self._speech = self._context.__enter__()

    def transcribe(self, audio_path: str) -> str:
        with self._lock:
            return self._speech.transcribe(audio=audio_path)["text"].strip()

    def close(self):
        self._context.__exit__(None, None, None)


def make_handler(transcriber, token):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):  # keep the console quiet; never log audio or text
            pass

        def _json(self, status, payload):
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/health":
                self._json(200, {"status": "ok", "model": MODEL_ID})
            else:
                self._json(404, {"error": "not found"})

        def do_POST(self):
            if self.path.rstrip("/") not in ("/v1/audio/transcriptions", "/audio/transcriptions"):
                return self._json(404, {"error": "not found"})
            if token and self.headers.get("Authorization") != f"Bearer {token}":
                return self._json(401, {"error": "invalid token"})
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_BODY:
                return self._json(413 if length > MAX_BODY else 400, {"error": "bad request size"})
            try:
                fields = parse_multipart(self.headers.get("Content-Type", ""), self.rfile.read(length))
                filename, audio = fields.get("file", (None, b""))
                if not audio:
                    return self._json(400, {"error": "missing 'file' field"})
            except Exception:
                return self._json(400, {"error": "could not parse multipart body"})

            suffix = os.path.splitext(filename or "")[1] or ".wav"
            fd, path = tempfile.mkstemp(suffix=suffix, prefix="parakeet-")
            try:
                with os.fdopen(fd, "wb") as handle:
                    handle.write(audio)
                text = transcriber.transcribe(path)
            except Exception as error:
                return self._json(500, {"error": f"transcription failed: {type(error).__name__}"})
            finally:
                try:
                    os.unlink(path)
                except OSError:
                    pass
            self._json(200, {"text": text})

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=int(os.environ.get("PARAKEET_PORT", "8765")))
    parser.add_argument("--device", default=os.environ.get("PARAKEET_DEVICE"), help="cpu, mps or cuda (default: auto)")
    parser.add_argument("--token", default=os.environ.get("PARAKEET_TOKEN"), help="require this bearer token")
    args = parser.parse_args()

    print(f"Loading {MODEL_ID} (first run downloads ~178 MB)…", flush=True)
    transcriber = Transcriber(args.device)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(transcriber, args.token))
    print(f"Ready: http://127.0.0.1:{args.port}/v1/audio/transcriptions", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        transcriber.close()


if __name__ == "__main__":
    main()
