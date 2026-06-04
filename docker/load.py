#!/usr/bin/env python3
"""HTTP load-test runner (vegeta).

Drives the vegeta static binary to fire a constant-rate request stream at a
single URL and summarizes latency percentiles (p50/p90/p95/p99), throughput,
success rate, and the status-code distribution. Driven by env vars set by
`bin/sandbox load`; honors SANDBOX_PROXY so the `--allow` egress boundary still
applies. Writes the raw vegeta JSON report into WORK_DIR and prints one JSON
line to stdout.

Env:
  LOAD_URL       (required) target URL
  LOAD_RATE      requests per second (default: 10)
  LOAD_DURATION  seconds (default: 10)
  LOAD_METHOD    GET/POST/... (default: GET)
  WORK_DIR       output dir (default: /work)
  SANDBOX_PROXY  optional egress proxy URL (Go-style HTTP(S)_PROXY)
"""
import json
import os
import subprocess
import sys


def main():
    url = os.environ.get("LOAD_URL", "").strip()
    if not url:
        print(json.dumps({"ok": False, "error": "LOAD_URL is required"}))
        return 1
    rate = os.environ.get("LOAD_RATE", "10").strip() or "10"
    duration = os.environ.get("LOAD_DURATION", "10").strip() or "10"
    method = os.environ.get("LOAD_METHOD", "GET").strip().upper() or "GET"
    work_dir = os.environ.get("WORK_DIR", "/work")

    env = dict(os.environ)
    proxy = os.environ.get("SANDBOX_PROXY", "").strip()
    if proxy:
        # vegeta is a Go binary; it honors the standard proxy env vars.
        env["HTTP_PROXY"] = proxy
        env["HTTPS_PROXY"] = proxy

    target = ("%s %s\n" % (method, url)).encode("utf-8")
    attack = ["vegeta", "attack", "-rate=%s" % rate,
              "-duration=%ss" % duration, "-timeout=30s"]
    try:
        atk = subprocess.run(attack, input=target, capture_output=True, env=env)
    except FileNotFoundError:
        print(json.dumps({"ok": False, "error": "vegeta binary not found"}))
        return 1
    if atk.returncode != 0 and not atk.stdout:
        print(json.dumps({"ok": False,
                          "error": atk.stderr.decode(errors="replace")[:500]}))
        return 1

    try:
        rep = subprocess.run(["vegeta", "report", "-type=json"],
                             input=atk.stdout, capture_output=True, env=env)
        data = json.loads(rep.stdout.decode())
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": "vegeta report parse failed: %s" % e}))
        return 1

    lat = data.get("latencies", {})

    def ns_to_ms(v):
        return round((v or 0) / 1e6, 2)

    result = {
        "ok": True,
        "url": url,
        "rate": int(float(rate)),
        "duration_s": int(float(duration)),
        "requests": data.get("requests"),
        "throughput": round(data.get("throughput", 0), 2),
        "success_rate": round(data.get("success", 0), 4),
        "status_codes": data.get("status_codes", {}),
        "latency_ms": {
            "mean": ns_to_ms(lat.get("mean")),
            "p50": ns_to_ms(lat.get("50th")),
            "p90": ns_to_ms(lat.get("90th")),
            "p95": ns_to_ms(lat.get("95th")),
            "p99": ns_to_ms(lat.get("99th")),
            "max": ns_to_ms(lat.get("max")),
        },
        "errors": data.get("errors") or [],
    }
    try:
        with open(os.path.join(work_dir, "vegeta-report.json"), "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
    except OSError:
        pass
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
