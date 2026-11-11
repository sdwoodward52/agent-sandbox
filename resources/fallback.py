#!/usr/bin/env python3
"""Local Gemini API fallback proxy for Continue Tab Autocomplete.

Automatically fails over across AGY_AUTOCOMPLETE_FALLBACK_MODELS on HTTP
403/404/429/5xx, empty thinking responses, or timeouts, with a 5-minute
circuit-breaker cooldown per model and silent graceful degradation.
"""
import http.server
import json
import os
import re
import socketserver
import sys
import time
import urllib.error
import urllib.request

DEFAULT_CHAIN = [
    m.strip()
    for m in os.environ.get(
        "AGY_AUTOCOMPLETE_FALLBACK_MODELS",
        "gemini-3.1-flash-lite,gemini-2.5-flash,gemini-flash-lite-latest,gemini-3.6-flash,gemini-3.5-flash,gemini-flash-latest",
    ).split(",")
    if m.strip()
]
UPSTREAM_BASE = "https://generativelanguage.googleapis.com"
COOLDOWN_SECONDS = 300.0
MODEL_PATH_RE = re.compile(r"^(/v1(?:beta)?/models/)([^/:]+)(:.*)$")
UNHEALTHY_UNTIL: dict[str, float] = {}
EMPTY_COMPLETION = (
    b'[{"candidates":[{"content":{"parts":[{"text":""}],"role":"model"},'
    b'"finishReason":"STOP"}]}]'
)


def candidate_models(requested: str) -> list[str]:
    now = time.monotonic()
    raw = [m for m in DEFAULT_CHAIN]
    if requested not in raw:
        raw.insert(0, requested)
    healthy = [m for m in raw if UNHEALTHY_UNTIL.get(m, 0.0) <= now]
    cooling = [m for m in raw if UNHEALTHY_UNTIL.get(m, 0.0) > now]
    return healthy + cooling


def adapt_payload_for_model(raw_body: bytes, model: str) -> bytes:
    if not raw_body:
        return raw_body
    try:
        data = json.loads(raw_body.decode("utf-8"))
        if not isinstance(data, dict):
            return raw_body
        gen_cfg = data.setdefault("generationConfig", {})
        if isinstance(gen_cfg, dict):
            if "2.5" in model:
                gen_cfg["thinkingConfig"] = {"thinkingBudget": 0}
            else:
                gen_cfg["thinkingConfig"] = {"thinkingLevel": "MINIMAL"}
            if not gen_cfg.get("maxOutputTokens"):
                gen_cfg["maxOutputTokens"] = 64
        return json.dumps(data).encode("utf-8")
    except Exception:
        return raw_body


def extract_clean_completion_payload(resp_body: bytes) -> bytes | None:
    stripped = resp_body.strip()
    if not stripped or stripped == b"[]":
        return None
    try:
        parsed = json.loads(stripped.decode("utf-8"))
        chunks = parsed if isinstance(parsed, list) else [parsed]
        text_fragments: list[str] = []
        for chunk in chunks:
            if not isinstance(chunk, dict) or "error" in chunk:
                return None
            cands = chunk.get("candidates")
            if not isinstance(cands, list):
                continue
            for cand in cands:
                if not isinstance(cand, dict):
                    continue
                parts = cand.get("content", {}).get("parts", [])
                if not isinstance(parts, list):
                    continue
                for p in parts:
                    if isinstance(p, dict) and not p.get("thought") and isinstance(p.get("text"), str):
                        text_fragments.append(p["text"])
        combined = "".join(text_fragments)
        if not combined:
            return None
        normalized = [
            {
                "candidates": [
                    {
                        "content": {
                            "parts": [{"text": combined}],
                            "role": "model",
                        },
                        "finishReason": "STOP",
                    }
                ]
            }
        ]
        return json.dumps(normalized).encode("utf-8")
    except Exception:
        return None


class FallbackHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:
        line = "[agy-gemini-fallback] " + (fmt % args) + "\n"
        sys.stderr.write(line)
        try:
            with open("/tmp/agy-gemini-fallback.log", "a", encoding="utf-8") as lf:
                lf.write(line)
        except Exception:
            pass

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length > 0 else b""
        match = MODEL_PATH_RE.match(self.path)
        if not match:
            self._send_json(200, EMPTY_COMPLETION, "none")
            return

        prefix, req_model, suffix = match.groups()
        candidates = candidate_models(req_model)

        for idx, model in enumerate(candidates):
            target_path = f"{prefix}{model}{suffix}"
            url = f"{UPSTREAM_BASE}{target_path}"
            model_body = adapt_payload_for_model(body, model)
            headers = {"Content-Type": self.headers.get("Content-Type", "application/json")}
            for h in ("x-goog-api-key", "accept"):
                if self.headers.get(h):
                    headers[h] = self.headers[h]
            req = urllib.request.Request(url, data=model_body, headers=headers, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=3.5) as resp:
                    resp_body = resp.read()
                    clean_payload = extract_clean_completion_payload(resp_body)
                    if not clean_payload:
                        UNHEALTHY_UNTIL[model] = time.monotonic() + COOLDOWN_SECONDS
                        self.log_message(
                            "model %s returned empty/unusable body; cooling down %ds (try %d/%d)",
                            model,
                            int(COOLDOWN_SECONDS),
                            idx + 1,
                            len(candidates),
                        )
                        continue
                    UNHEALTHY_UNTIL.pop(model, None)
                    self.log_message("served completion via %s (%d bytes)", model, len(clean_payload))
                    self._send_json(200, clean_payload, model)
                    return
            except urllib.error.HTTPError as exc:
                _ = exc.read()
                UNHEALTHY_UNTIL[model] = time.monotonic() + COOLDOWN_SECONDS
                self.log_message(
                    "model %s returned HTTP %d; cooling down %ds (try %d/%d)",
                    model,
                    exc.code,
                    int(COOLDOWN_SECONDS),
                    idx + 1,
                    len(candidates),
                )
                continue
            except Exception as exc:
                UNHEALTHY_UNTIL[model] = time.monotonic() + COOLDOWN_SECONDS
                self.log_message("model %s failed (%s); trying next fallback", model, exc)
                continue

        self.log_message("all candidate models unavailable; returning silent empty completion")
        self._send_json(200, EMPTY_COMPLETION, "fallback-silent")

    def _send_json(self, status: int, data: bytes, model: str) -> None:
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("X-Agy-Selected-Model", model)
            self.end_headers()
            self.wfile.write(data)
        except BrokenPipeError:
            pass


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    port = int(os.environ.get("AGY_FALLBACK_PORT", "11435"))
    try:
        srv = ThreadedHTTPServer(("127.0.0.1", port), FallbackHandler)
    except OSError:
        sys.exit(0)
    srv.serve_forever()
