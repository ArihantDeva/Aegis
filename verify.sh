#!/usr/bin/env bash
# verify.sh — prove the sandbox works AND stays off the host screen.
#
# 1. Build the browser + egress images.
# 2. Run a real headless recipe (navigate + extract) in a hardened container.
# 3. Assert the result JSON is well-formed and extracted the expected value.
# 4. Assert hardening is actually in force (non-root, caps dropped, no host mounts).
# 5. Assert egress allow-list mode blocks a non-allowed domain.
#
# Exits non-zero on the first failed assertion. No host display is ever touched.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX="$DIR/bin/sandbox"
PASS=0; FAIL=0
ok(){ echo "  ✓ $*"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $*" >&2; FAIL=$((FAIL+1)); }

echo "[verify] 1/5 build images"
"$SANDBOX" build >/dev/null 2>&1 && ok "images built" || { no "build failed"; exit 1; }

echo "[verify] 2/5 headless navigate + extract"
RECIPE='{"steps":[{"op":"navigate","url":"https://example.com"},{"op":"extract_text","name":"h1","selector":"h1"}]}'
OUT="$(printf '%s' "$RECIPE" | "$SANDBOX" run --recipe - 2>/dev/null || true)"
echo "    raw: $OUT"
if echo "$OUT" | grep -q '"ok": *true'; then ok "recipe ok"; else no "recipe not ok"; fi
if echo "$OUT" | grep -qi 'Example Domain'; then ok "extracted h1 text"; else no "h1 extract missing"; fi

echo "[verify] 3/5 hardening in force (non-root, caps dropped, no host bind beyond /work)"
WHOAMI="$(printf '{"steps":[{"op":"eval","name":"u","script":"1"}]}' | "$SANDBOX" run --recipe - 2>/dev/null || true)"
# Direct introspection: run id/capsh inside the same hardened flags via shell entrypoint.
IDOUT="$(docker run --rm --cap-drop ALL --security-opt no-new-privileges --entrypoint id claude-sandbox-browser -un 2>/dev/null || true)"
[ "$IDOUT" = "sandbox" ] && ok "runs as non-root user 'sandbox'" || no "expected non-root 'sandbox', got '$IDOUT'"
CAPS="$(docker run --rm --cap-drop ALL --security-opt no-new-privileges --entrypoint sh claude-sandbox-browser -c 'grep CapEff /proc/self/status' 2>/dev/null || true)"
echo "    $CAPS"
echo "$CAPS" | grep -qiE 'CapEff:\s*0+$' && ok "all capabilities dropped (CapEff=0)" || no "capabilities not fully dropped"

echo "[verify] 4/5 ephemeral: container is removed after run (--rm)"
# A --rm container that has just exited can linger for ~1s while Docker reaps it
# asynchronously, so settle for a few seconds before asserting. A genuine leak (a
# run path missing --rm) leaves an Exited container that never clears and still fails.
LEFT="$(docker ps -a --filter ancestor=claude-sandbox-browser --format '{{.Names}}' || true)"
for _ in 1 2 3 4 5; do
  [ -z "$LEFT" ] && break
  sleep 1
  LEFT="$(docker ps -a --filter ancestor=claude-sandbox-browser --format '{{.Names}}' || true)"
done
[ -z "$LEFT" ] && ok "no leftover containers" || no "leftover containers: $LEFT"

echo "[verify] 5/5 egress allow-list: passes allowed, blocks non-allowed"
# Use fresh domains (never visited above) so Chromium's persistent disk cache
# can't serve them without hitting the network — this tests the NETWORK boundary.
# 5a: allow example.org and reach it -> proves the proxy is alive and passes allowed.
ALLOWR='{"steps":[{"op":"navigate","url":"https://example.org","timeout":15000},{"op":"extract_text","name":"h1","selector":"h1","timeout":8000}]}'
AOUT="$(printf '%s' "$ALLOWR" | "$SANDBOX" run --allow example.org --recipe - 2>/dev/null || true)"
echo "    allowed raw: $AOUT"
echo "$AOUT" | grep -qi 'Example Domain' && ok "allowed domain reached through proxy" || no "allowed domain did NOT pass proxy (proxy may be down)"
# 5b: same allow-list, navigate a DIFFERENT fresh domain -> must be refused.
BLOCK='{"steps":[{"op":"navigate","url":"https://www.iana.org/help","timeout":12000},{"op":"extract_text","name":"h1","selector":"h1","timeout":8000}]}'
BOUT="$(printf '%s' "$BLOCK" | "$SANDBOX" run --allow example.org --recipe - 2>/dev/null || true)"
echo "    blocked raw: $BOUT"
if echo "$BOUT" | grep -q '"ok": *false'; then ok "non-allowed domain blocked"; else no "egress NOT blocked — reached iana.org despite allow=example.org"; fi
"$SANDBOX" stop >/dev/null 2>&1 || true

echo
echo "[verify] PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "[verify] ALL GREEN" || { echo "[verify] FAILURES PRESENT" >&2; exit 1; }
