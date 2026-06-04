#!/usr/bin/env python3
"""HTTP-impersonation fetch tier (curl_cffi).

A non-browser HTTP(S) client that mimics a real browser's TLS/JA3 + HTTP/2
fingerprint, for sites that fingerprint the transport but do not need a rendered
DOM. Far lighter than launching Chromium, far higher fidelity than a raw
`requests` call. Driven entirely by env vars (set by `bin/sandbox
fetch-impersonate`); writes the response body + metadata into WORK_DIR and prints
one JSON line to stdout.

Honors SANDBOX_PROXY when set so the `--allow` egress boundary still applies: the
TLS handshake is CONNECT-tunneled through the tinyproxy sidecar, so the browser
fingerprint is preserved end-to-end.

Env:
  HTTP_URL          (required) target URL
  HTTP_IMPERSONATE  curl_cffi target profile (default: chrome120)
  HTTP_METHOD       GET/POST/... (default: GET)
  HTTP_HEADERS      extra headers, "Key:Value,Key:Value"
  HTTP_BODY         raw request body (utf-8)
  HTTP_TIMEOUT      seconds (default: 30)
  WORK_DIR          output dir (default: /work)
  SANDBOX_PROXY     optional egress proxy URL
"""
import json
import os
import sys
import time


def _parse_headers(raw):
    headers = {}
    for pair in (raw or "").split(","):
        pair = pair.strip()
        if not pair or ":" not in pair:
            continue
        key, _, val = pair.partition(":")
        if key.strip():
            headers[key.strip()] = val.strip()
    return headers


def main():
    url = os.environ.get("HTTP_URL", "").strip()
    if not url:
        print(json.dumps({"ok": False, "error": "HTTP_URL is required"}))
        return 1

    impersonate = os.environ.get("HTTP_IMPERSONATE", "chrome120").strip() or "chrome120"
    method = os.environ.get("HTTP_METHOD", "GET").strip().upper() or "GET"
    headers = _parse_headers(os.environ.get("HTTP_HEADERS", ""))
    body = os.environ.get("HTTP_BODY", "")
    try:
        timeout = float(os.environ.get("HTTP_TIMEOUT", "30") or "30")
    except ValueError:
        timeout = 30.0
    work_dir = os.environ.get("WORK_DIR", "/work")

    proxies = None
    proxy = os.environ.get("SANDBOX_PROXY", "").strip()
    if proxy:
        proxies = {"http": proxy, "https": proxy}

    try:
        from curl_cffi import requests as cffi_requests
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": "curl_cffi import failed: %s" % e}))
        return 1

    start = time.monotonic()
    try:
        with cffi_requests.Session() as sess:
            resp = sess.request(
                method, url,
                headers=headers or None,
                data=body.encode("utf-8") if body else None,
                timeout=timeout,
                impersonate=impersonate,
                proxies=proxies,
                allow_redirects=True,
            )
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": str(e), "url": url,
                          "impersonate": impersonate}))
        return 1
    elapsed_ms = int((time.monotonic() - start) * 1000)

    content = resp.content or b""
    ctype = (resp.headers.get("content-type", "") or "").lower()
    if "html" in ctype:
        ext = "html"
    elif any(t in ctype for t in ("text", "json", "xml", "javascript")):
        ext = "txt"
    else:
        ext = "bin"
    body_path = os.path.join(work_dir, "body.%s" % ext)
    try:
        with open(body_path, "wb") as fh:
            fh.write(content)
    except OSError:
        body_path = None

    result = {
        "ok": bool(resp.ok),
        "status": resp.status_code,
        "url": str(resp.url),
        "elapsed_ms": elapsed_ms,
        "impersonate": impersonate,
        "bytes": len(content),
        "content_type": resp.headers.get("content-type", ""),
        "body_path": body_path,
        "headers": dict(resp.headers),
    }
    try:
        with open(os.path.join(work_dir, "result.json"), "w", encoding="utf-8") as fh:
            json.dump(result, fh, indent=2)
    except OSError:
        pass
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
