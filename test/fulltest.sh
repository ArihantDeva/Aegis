#!/usr/bin/env bash
# fulltest.sh — exhaustive functional test of the Docker web sandbox.
#
# Covers every CLI path and recipe op: the interactive/extract ops, error
# handling, the network boundary (offline / bridge / allow-list), screenshot
# confinement, profile persistence + isolation, lock self-heal, observe mode,
# AND the opt-in capability layer (stealth engine, markdown/article extraction,
# trace/HAR/video artifacts, read-only rootfs, the LLM agent runner wiring).
#
# Needs the image built (bin/sandbox build) and the Docker daemon up. Nothing
# ever touches the host screen. Live LLM and FlareSolverr paths are import/wiring
# checks by default; set SANDBOX_VERIFY_CF=1 to also exercise the ~1GB cf-get pull.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$DIR/bin/sandbox"
IMG=claude-sandbox-browser
WORK=/tmp/sbtest-work
PASS=0; FAIL=0
ok(){ echo "  ✓ $*"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $*" >&2; FAIL=$((FAIL+1)); }
rm -rf "$WORK"; mkdir -p "$WORK"
# Wipe test profile subdirs so persistence/isolation assertions are deterministic.
docker run --rm -v sandbox-profile:/profile --entrypoint sh "$IMG" \
  -c 'rm -rf /profile/offlineprobe /profile/persisttest /profile/isoA /profile/isoB /profile/healtest' >/dev/null 2>&1 || true

# ---- build a base64 data: URL form so ops run deterministically offline ----
HTML='<html><body><form>
<input id="name" name="name">
<input id="email" name="email">
<select id="color"><option value="red">red</option><option value="blue">blue</option></select>
<input type="checkbox" id="agree">
<input type="checkbox" id="agree2" checked>
<input type="file" id="file">
<button type="button" id="btn" onclick="document.getElementById(&quot;out&quot;).innerText=&quot;clicked&quot;">Go</button>
<div id="out" data-state="init">init</div>
</form></body></html>'
B64=$(printf '%s' "$HTML" | base64 | tr -d '\n')
DATAURL="data:text/html;base64,$B64"
echo "hello-upload" > "$WORK/upload.txt"

echo "=== T1: all interactive + extract ops (offline, data: URL) ==="
jq -n --arg u "$DATAURL" '{steps:[
  {op:"navigate",url:$u},
  {op:"fill",selector:"#name",text:"Sandbox"},
  {op:"fill_form",fields:{"#email":"d@x.com"}},
  {op:"select",selector:"#color",value:"blue"},
  {op:"check",selector:"#agree"},
  {op:"uncheck",selector:"#agree2"},
  {op:"press",selector:"#name",key:"Tab"},
  {op:"upload",selector:"#file",files:["/work/upload.txt"]},
  {op:"click",selector:"#btn"},
  {op:"extract_text",name:"out",selector:"#out"},
  {op:"extract_attr",name:"state",selector:"#out",attr:"data-state"},
  {op:"eval",name:"nameval",script:"document.getElementById(\"name\").value"},
  {op:"eval",name:"colorval",script:"document.getElementById(\"color\").value"},
  {op:"eval",name:"agreechk",script:"document.getElementById(\"agree\").checked"},
  {op:"eval",name:"agree2chk",script:"document.getElementById(\"agree2\").checked"},
  {op:"eval",name:"fname",script:"document.getElementById(\"file\").files[0].name"},
  {op:"screenshot",path:"form.png"},
  {op:"sleep",ms:150}
]}' > "$WORK/t1.json"
T1=$("$SB" run --offline --work "$WORK" --recipe "$WORK/t1.json" 2>/dev/null)
echo "    $T1"
echo "$T1" | jq -e '.ok==true' >/dev/null && ok "T1 ok" || no "T1 not ok"
echo "$T1" | jq -e '.extracted.out=="clicked"' >/dev/null && ok "click + extract_text" || no "click/extract_text"
echo "$T1" | jq -e '.extracted.state=="init"' >/dev/null && ok "extract_attr" || no "extract_attr"
echo "$T1" | jq -e '.extracted.nameval=="Sandbox"' >/dev/null && ok "fill + eval" || no "fill/eval"
echo "$T1" | jq -e '.extracted.colorval=="blue"' >/dev/null && ok "select" || no "select"
echo "$T1" | jq -e '.extracted.agreechk==true' >/dev/null && ok "check" || no "check"
echo "$T1" | jq -e '.extracted.agree2chk==false' >/dev/null && ok "uncheck" || no "uncheck"
echo "$T1" | jq -e '.extracted.fname=="upload.txt"' >/dev/null && ok "upload" || no "upload"
[ -f "$WORK/form.png" ] && ok "screenshot written to --work" || no "screenshot missing"

echo "=== T2: error handling (bad selector -> ok:false, exit 1) ==="
jq -n --arg u "$DATAURL" '{steps:[{op:"navigate",url:$u},{op:"extract_text",name:"x",selector:"#nope",timeout:1500}]}' > "$WORK/t2.json"
T2=$("$SB" run --offline --work "$WORK" --recipe "$WORK/t2.json" 2>/dev/null); RC=$?
echo "    rc=$RC $T2"
echo "$T2" | jq -e '.ok==false and (.errors|length>0)' >/dev/null && ok "error surfaced as ok:false" || no "error not surfaced"
[ "$RC" -eq 1 ] && ok "exit code 1 on failure" || no "expected exit 1, got $RC"

echo "=== T3: offline mode blocks real network (fresh uncached profile) ==="
T3=$(printf '%s' '{"steps":[{"op":"navigate","url":"https://example.com","timeout":8000}]}' | "$SB" run --offline --profile offlineprobe --recipe - 2>/dev/null)
echo "    $T3"
echo "$T3" | jq -e '.ok==false' >/dev/null && ok "offline blocks network (no cache fallback)" || no "offline did NOT block"

echo "=== T4: default bridge reaches internet ==="
T4=$(printf '%s' '{"steps":[{"op":"navigate","url":"https://example.com"},{"op":"extract_text","name":"h","selector":"h1"}]}' | "$SB" run --recipe - 2>/dev/null)
echo "    $T4"
echo "$T4" | jq -e '.extracted.h=="Example Domain"' >/dev/null && ok "bridge reaches example.com" || no "bridge failed"

echo "=== T5: screenshot path confinement (/etc escape -> /work) ==="
jq -n --arg u "$DATAURL" '{steps:[{op:"navigate",url:$u},{op:"screenshot",path:"/etc/sbescape.png"}]}' > "$WORK/t5.json"
T5=$("$SB" run --offline --work "$WORK" --recipe "$WORK/t5.json" 2>/dev/null)
echo "    $T5"
[ ! -f /etc/sbescape.png ] && ok "no write to /etc" || no "ESCAPED to /etc!"
[ -f "$WORK/sbescape.png" ] && ok "screenshot confined to /work" || no "confined file missing"

echo "=== T6: profile persistence (persistent cookie survives across runs) ==="
jq -n '{steps:[{op:"navigate",url:"https://example.com"},{op:"eval",name:"s",script:"(() => { document.cookie = \"sbtest=42;path=/;max-age=3600\"; return \"set\"; })()"}]}' > "$WORK/t6set.json"
jq -n '{steps:[{op:"navigate",url:"https://example.com"},{op:"eval",name:"c",script:"document.cookie"}]}' > "$WORK/t6get.json"
"$SB" run --profile persisttest --recipe "$WORK/t6set.json" >/dev/null 2>&1
T6=$("$SB" run --profile persisttest --recipe "$WORK/t6get.json" 2>/dev/null)
echo "    $T6"
echo "$T6" | jq -e '.extracted.c|test("sbtest=42")' >/dev/null && ok "persistent cookie survived across runs (logins will persist)" || no "cookie did NOT persist"

echo "=== T7: allow-list passes allowed, blocks others ==="
A=$(printf '%s' '{"steps":[{"op":"navigate","url":"https://example.org","timeout":15000},{"op":"extract_text","name":"h","selector":"h1"}]}' | "$SB" run --allow example.org --recipe - 2>/dev/null)
echo "    allowed: $A"
echo "$A" | jq -e '.extracted.h=="Example Domain"' >/dev/null && ok "allowed domain passes proxy" || no "allowed domain failed"
B=$(printf '%s' '{"steps":[{"op":"navigate","url":"https://www.iana.org/help","timeout":12000}]}' | "$SB" run --allow example.org --recipe - 2>/dev/null)
echo "    blocked: $B"
echo "$B" | jq -e '.ok==false' >/dev/null && ok "non-allowed domain blocked" || no "non-allowed NOT blocked"

echo "=== T8: custom --mem/--cpus still runs ==="
T8=$(printf '%s' '{"steps":[{"op":"navigate","url":"https://example.com"},{"op":"extract_text","name":"h","selector":"h1"}]}' | "$SB" run --mem 1g --cpus 1 --recipe - 2>/dev/null)
echo "$T8" | jq -e '.extracted.h=="Example Domain"' >/dev/null && ok "custom resource caps OK" || no "custom caps failed"

echo "=== T9: observe mode serves noVNC on localhost:6080 ==="
"$SB" observe >/dev/null 2>&1
for i in $(seq 1 20); do curl -s -o /dev/null -w '%{http_code}' http://localhost:6080/vnc.html 2>/dev/null | grep -q 200 && break; sleep 1; done
CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:6080/vnc.html 2>/dev/null)
echo "    noVNC HTTP $CODE"
[ "$CODE" = "200" ] && ok "observe noVNC reachable on 127.0.0.1:6080" || no "observe noVNC not reachable ($CODE)"
PUBLISH=$(docker port sandbox-observe 6080 2>/dev/null)
echo "    published: $PUBLISH"
echo "$PUBLISH" | grep -q '127.0.0.1' && ok "noVNC bound to localhost only" || no "noVNC not localhost-bound"

echo "=== T10: stop tears down observe + proxy + networks ==="
"$SB" stop >/dev/null 2>&1
docker ps -a --format '{{.Names}}' | grep -qE 'sandbox-(observe|proxy|cf)' && no "containers remain after stop" || ok "containers removed"
docker network ls --format '{{.Name}}' | grep -qE 'sandbox-(int|ext)' && no "networks remain after stop" || ok "networks removed"

echo "=== T11: image shell entrypoint works (sandbox shell substrate) ==="
SH=$(docker run --rm --cap-drop ALL --security-opt no-new-privileges --entrypoint bash "$IMG" -lc 'echo shell-ok; python3 -c "import playwright,sys;print(sys.version.split()[0])"' 2>/dev/null)
echo "    $SH"
echo "$SH" | grep -q 'shell-ok' && ok "shell substrate runs" || no "shell substrate failed"

echo "=== T12: named profiles are isolated (cookie in A not visible in B) ==="
jq -n '{steps:[{op:"navigate",url:"https://example.com"},{op:"eval",name:"s",script:"(() => { document.cookie = \"isocookie=AAA;path=/;max-age=3600\"; return \"set\"; })()"}]}' > "$WORK/isoset.json"
jq -n '{steps:[{op:"navigate",url:"https://example.com"},{op:"eval",name:"c",script:"document.cookie"}]}' > "$WORK/isoget.json"
"$SB" run --profile isoA --recipe "$WORK/isoset.json" >/dev/null 2>&1
ISOB=$("$SB" run --profile isoB --recipe "$WORK/isoget.json" 2>/dev/null)
echo "    profile B sees: $ISOB"
echo "$ISOB" | jq -e '(.extracted.c|test("isocookie"))|not' >/dev/null && ok "profile B cannot see profile A's cookie (isolated)" || no "profiles leaked cookies"

echo "=== T13: stale SingletonLock self-heals (no permanent brick) ==="
docker run --rm -v sandbox-profile:/profile --entrypoint sh "$IMG" \
  -c 'mkdir -p /profile/healtest && ln -sf deadhost-12345 /profile/healtest/SingletonLock' >/dev/null 2>&1
T13=$(printf '%s' '{"steps":[{"op":"navigate","url":"https://example.com"},{"op":"extract_text","name":"h","selector":"h1"}]}' | "$SB" run --profile healtest --recipe - 2>/dev/null)
echo "    $T13"
echo "$T13" | jq -e '.extracted.h=="Example Domain"' >/dev/null && ok "run self-healed stale lock and succeeded" || no "stale lock bricked the run"

# ----------------------------------------------------------------------------
# Opt-in capability layer (everything below is new surface, all off by default).
# ----------------------------------------------------------------------------

echo "=== T14: extract_markdown turns rendered HTML into markdown (offline) ==="
MDHTML='<html><body><article><h1>Release Notes</h1><p>The widget now supports <strong>dark mode</strong> and faster startup.</p></article></body></html>'
MDURL="data:text/html;base64,$(printf '%s' "$MDHTML" | base64 | tr -d '\n')"
jq -n --arg u "$MDURL" '{steps:[{op:"navigate",url:$u},{op:"extract_markdown",name:"md","selector":"article"}]}' > "$WORK/t14.json"
T14=$("$SB" run --offline --work "$WORK" --recipe "$WORK/t14.json" 2>/dev/null)
echo "    $T14"
echo "$T14" | jq -e '.extracted.md|test("Release Notes")' >/dev/null && ok "markdown carries heading text" || no "markdown heading missing"
echo "$T14" | jq -e '.extracted.md|test("dark mode")' >/dev/null && ok "markdown carries body text" || no "markdown body missing"

echo "=== T15: extract_article pulls clean article text (trafilatura, offline) ==="
ARTHTML='<html><head><title>Quarterly Report</title></head><body><article><h1>Quarterly Report</h1><p>Revenue increased substantially across all regions during the period under review, driven by strong demand.</p><p>The board approved a new initiative to expand into adjacent markets over the coming year.</p><p>Management remains confident about the long term outlook despite ongoing headwinds.</p></article></body></html>'
ARTURL="data:text/html;base64,$(printf '%s' "$ARTHTML" | base64 | tr -d '\n')"
jq -n --arg u "$ARTURL" '{steps:[{op:"navigate",url:$u},{op:"extract_article",name:"art"}]}' > "$WORK/t15.json"
T15=$("$SB" run --offline --work "$WORK" --recipe "$WORK/t15.json" 2>/dev/null)
echo "    $T15"
echo "$T15" | jq -e '.extracted.art|test("Revenue increased")' >/dev/null && ok "article body extracted" || no "article body missing"

echo "=== T16: stealth engine (patchright) loads + drives a real page ==="
T16=$(printf '%s' '{"steps":[{"op":"navigate","url":"https://example.com"},{"op":"extract_text","name":"h","selector":"h1"}]}' | "$SB" run --stealth --recipe - 2>/dev/null)
echo "    $T16"
echo "$T16" | jq -e '.extracted.h=="Example Domain"' >/dev/null && ok "stealth engine ran a real navigation" || no "stealth run failed"

echo "=== T17: --trace writes a Playwright trace.zip into /work ==="
rm -f "$WORK/trace.zip"
T17=$(printf '%s' '{"steps":[{"op":"navigate","url":"https://example.com"},{"op":"extract_text","name":"h","selector":"h1"}]}' | "$SB" run --trace --work "$WORK" --recipe - 2>/dev/null)
echo "    $T17"
echo "$T17" | jq -e '.extracted._artifacts.trace|test("trace.zip")' >/dev/null && ok "trace path reported in JSON" || no "trace path missing in JSON"
[ -s "$WORK/trace.zip" ] && ok "trace.zip written to /work" || no "trace.zip missing"

echo "=== T18: --har writes network.har into /work ==="
rm -f "$WORK/network.har"
T18=$(printf '%s' '{"steps":[{"op":"navigate","url":"https://example.com"},{"op":"extract_text","name":"h","selector":"h1"}]}' | "$SB" run --har --work "$WORK" --recipe - 2>/dev/null)
echo "    $T18"
[ -s "$WORK/network.har" ] && ok "network.har written to /work" || no "network.har missing"
jq -e '.log.entries|length>0' "$WORK/network.har" >/dev/null 2>&1 && ok "HAR captured >=1 request" || no "HAR has no entries"

echo "=== T19: --video writes a .webm into /work ==="
rm -f "$WORK"/*.webm
T19=$(printf '%s' '{"steps":[{"op":"navigate","url":"https://example.com"},{"op":"extract_text","name":"h","selector":"h1"},{"op":"sleep","ms":400}]}' | "$SB" run --video --work "$WORK" --recipe - 2>/dev/null)
echo "    $T19"
ls "$WORK"/*.webm >/dev/null 2>&1 && ok "video .webm written to /work" || no "video .webm missing"

echo "=== T20: --readonly runs on an immutable root fs ==="
# 20a: the recipe still works with a read-only root + tmpfs HOME.
T20=$(printf '%s' '{"steps":[{"op":"navigate","url":"https://example.com"},{"op":"extract_text","name":"h","selector":"h1"}]}' | "$SB" run --readonly --recipe - 2>/dev/null)
echo "    $T20"
echo "$T20" | jq -e '.extracted.h=="Example Domain"' >/dev/null && ok "run succeeds under read-only rootfs" || no "read-only run failed"
# 20b: prove the root really is immutable (writing to / is refused).
ROW=$(docker run --rm --read-only --tmpfs /tmp --entrypoint sh "$IMG" -c 'touch /pwned 2>&1 || echo REFUSED' 2>/dev/null)
echo "    rootfs write -> $ROW"
echo "$ROW" | grep -q 'REFUSED' && ok "root filesystem is immutable" || no "root fs was writable!"

echo "=== T21: LLM agent runner is wired (deps import; missing key fails fast) ==="
# 21a: the agent venv has browser-use and agent.py's imports resolve.
AGI=$(docker run --rm --entrypoint /opt/agentvenv/bin/python "$IMG" -c 'import browser_use; from browser_use import Agent, Browser; print("agent-import-ok")' 2>/dev/null)
echo "    $AGI"
echo "$AGI" | grep -q 'agent-import-ok' && ok "browser-use imports in agent venv" || no "agent venv import failed"
# 21b: agent.py itself parses + its _make_llm raises the documented error with no key.
AGE=$(docker run --rm -e OPENAI_API_KEY= -e ANTHROPIC_API_KEY= -e GOOGLE_API_KEY= -e OPENAI_BASE_URL= \
        -e PYTHONPATH=/opt \
        --entrypoint /opt/agentvenv/bin/python "$IMG" -c 'import agent;
try:
    agent._make_llm()
    print("NO-ERROR")
except SystemExit as e:
    print("guarded:", "no LLM configured" in str(e))' 2>/dev/null)
echo "    $AGE"
echo "$AGE" | grep -q 'guarded: True' && ok "agent fails fast + clearly without a key" || no "agent key-guard missing"
# 21c: the CLI refuses `sandbox agent` with no key BEFORE launching docker.
AGC=$(env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u GOOGLE_API_KEY -u OPENAI_BASE_URL "$SB" agent "do nothing" 2>&1 || true)
echo "    $AGC"
echo "$AGC" | grep -qi 'no LLM key' && ok "CLI guards agent against missing key" || no "CLI did not guard agent"

echo "=== T22: each venv carries exactly its own deps (isolated, no co-resolve) ==="
DDEPS=$(docker run --rm --entrypoint /opt/venv/bin/python "$IMG" -c 'import playwright, trafilatura, markdownify; print("driver-deps-ok")' 2>/dev/null)
echo "    driver: $DDEPS"
echo "$DDEPS" | grep -q 'driver-deps-ok' && ok "driver venv: playwright + trafilatura + markdownify" || no "driver venv deps missing"
SDEPS=$(docker run --rm --entrypoint /opt/stealthvenv/bin/python "$IMG" -c 'import patchright, trafilatura, markdownify; print("stealth-deps-ok")' 2>/dev/null)
echo "    stealth: $SDEPS"
echo "$SDEPS" | grep -q 'stealth-deps-ok' && ok "stealth venv: patchright + trafilatura + markdownify" || no "stealth venv deps missing"

if [ "${SANDBOX_VERIFY_CF:-0}" = "1" ]; then
  echo "=== T23: cf-get fetches through FlareSolverr (pulls ~1GB image) ==="
  CF=$("$SB" cf-get --work "$WORK" https://example.com 2>/dev/null)
  echo "    $CF"
  echo "$CF" | jq -e '.ok==true' >/dev/null && ok "cf-get returned ok" || no "cf-get not ok"
  [ -s "$WORK/cf-page.html" ] && ok "cf-page.html written" || no "cf-page.html missing"
  "$SB" stop >/dev/null 2>&1 || true
else
  echo "=== T23: cf-get live pull SKIPPED (set SANDBOX_VERIFY_CF=1 to run) ==="
fi

echo "=== T24: 'pdf' op renders the page to a PDF in /work (default engine) ==="
rm -f "$WORK"/*.pdf
T24=$(printf '%s' '{"steps":[{"op":"navigate","url":"data:text/html,<h1>Invoice</h1><p>Total 42</p>"},{"op":"pdf","path":"page.pdf"}]}' | "$SB" run --work "$WORK" --recipe - 2>/dev/null)
echo "    $T24"
echo "$T24" | jq -e '.extracted._pdfs[0]|test("page.pdf")' >/dev/null && ok "pdf path reported in JSON" || no "pdf path missing in JSON"
[ -s "$WORK/page.pdf" ] && ok "page.pdf written to /work" || no "page.pdf missing"
grep -q '%PDF' "$WORK/page.pdf" && ok "file is a valid PDF (%PDF header)" || no "not a valid PDF"

echo "=== T25: 'convert' turns a document into Markdown (markitdown, isolated venv) ==="
# Reuse the PDF rendered by T24 (page.pdf in $WORK); convert it back to Markdown.
rm -f "$WORK/page.md"
if [ -s "$WORK/page.pdf" ]; then
  T25=$("$SB" convert "$WORK/page.pdf" 2>/dev/null)
  echo "    $(printf '%s' "$T25" | head -c 200)"
  echo "$T25" | jq -e '.ok==true' >/dev/null && ok "convert reports ok" || no "convert not ok"
  echo "$T25" | jq -e '.markdown|test("Invoice")' >/dev/null && ok "markdown recovers source text (Invoice)" || no "markdown missing source text"
  [ -s "$WORK/page.md" ] && ok "page.md written beside the source" || no "page.md missing"
else
  no "T25 skipped: T24 produced no page.pdf to convert"
fi
# Verify the convert venv is isolated and carries markitdown.
CDEPS=$(docker run --rm --entrypoint /opt/convertvenv/bin/python "$IMG" -c 'import markitdown; print("convert-deps-ok")' 2>/dev/null)
echo "    convert: $CDEPS"
echo "$CDEPS" | grep -q 'convert-deps-ok' && ok "convert venv: markitdown present (isolated)" || no "convert venv deps missing"

echo "=== T26: --camoufox (undetectable Firefox engine) loads + drives a real page ==="
T26=$(printf '%s' '{"steps":[{"op":"navigate","url":"https://example.com"},{"op":"extract_text","name":"h","selector":"h1"}]}' | "$SB" run --camoufox --recipe - 2>/dev/null)
echo "    $T26"
echo "$T26" | jq -e '.extracted.h=="Example Domain"' >/dev/null && ok "camoufox engine ran a real navigation" || no "camoufox run failed"
# Verify the camoufox venv is isolated and carries camoufox + its fetched Firefox.
XDEPS=$(docker run --rm --entrypoint /opt/camoufoxvenv/bin/python "$IMG" -c 'import camoufox; from camoufox.sync_api import Camoufox; print("camoufox-deps-ok")' 2>/dev/null)
echo "    camoufox: $XDEPS"
echo "$XDEPS" | grep -q 'camoufox-deps-ok' && ok "camoufox venv: camoufox present (isolated)" || no "camoufox venv deps missing"
# Camoufox honors the allow-list egress boundary (Firefox routes through the proxy):
# allowed passes, non-allowed is refused. Guards the geoip-vs-allowlist regression
# (auto geoip would call api.ipify.org through the proxy and 403 the whole launch).
CFA=$(printf '%s' '{"steps":[{"op":"navigate","url":"https://example.com","timeout":30000},{"op":"extract_text","name":"h","selector":"h1"}]}' | "$SB" run --camoufox --allow example.com --recipe - 2>/dev/null)
echo "    camoufox+allow allowed: $CFA"
echo "$CFA" | jq -e '.extracted.h=="Example Domain"' >/dev/null && ok "camoufox reaches allowed domain through proxy" || no "camoufox allow-list passthrough failed"
CFB=$(printf '%s' '{"steps":[{"op":"navigate","url":"https://www.iana.org/help","timeout":20000}]}' | "$SB" run --camoufox --allow example.com --recipe - 2>/dev/null)
echo "    camoufox+allow blocked: $CFB"
echo "$CFB" | jq -e '.ok==false' >/dev/null && ok "camoufox blocks non-allowed domain (egress boundary holds)" || no "camoufox did NOT block non-allowed"
"$SB" stop >/dev/null 2>&1 || true

echo "=== T27: fetch-media venv wiring (yt-dlp import; offline-mode guard) ==="
# 27a: yt-dlp is importable in the media venv and the module version is present.
MDEPS=$(docker run --rm --entrypoint /opt/mediavenv/bin/python "$IMG" \
  -c 'import yt_dlp; print("media-deps-ok")' 2>/dev/null)
echo "    media venv: $MDEPS"
echo "$MDEPS" | grep -q 'media-deps-ok' && ok "media venv: yt-dlp importable" || no "media venv yt-dlp missing"
# 27b: RUNNER=media with no URL fails fast with a structured error.
NURL=$(docker run --rm \
  -e RUNNER=media -e MEDIA_URL="" -e WORK_DIR=/work \
  --network none --entrypoint /opt/mediavenv/bin/python "$IMG" /opt/media.py 2>/dev/null)
echo "    no-url guard: $NURL"
echo "$NURL" | jq -e '.ok==false' >/dev/null && ok "MEDIA_URL unset returns ok:false" || no "missing URL guard missing"
# 27c: fetching from a real URL while --offline (network none) produces ok:false.
if [ "${SANDBOX_VERIFY_MEDIA:-0}" != "1" ]; then
  T27=$(docker run --rm \
    -e RUNNER=media -e MEDIA_URL="https://www.youtube.com/watch?v=dQw4w9WgXcQ" \
    -e MEDIA_FORMAT="best" -e MEDIA_SKIP_DOWNLOAD="1" -e WORK_DIR=/work \
    --network none --tmpfs /work:rw,size=64m \
    "$IMG" 2>/dev/null)
  echo "    offline fetch: $T27"
  echo "$T27" | jq -e '.ok==false' >/dev/null && ok "fetch-media offline returns ok:false (network blocked)" || no "offline did NOT block media fetch"
else
  echo "=== T27c: live media fetch (SANDBOX_VERIFY_MEDIA=1) ==="
  rm -rf "$WORK"/media-test && mkdir -p "$WORK/media-test"
  T27L=$("$SB" fetch-media --work "$WORK/media-test" --skip-download \
    --allow youtube.com,googlevideo.com,yt3.ggpht.com,i.ytimg.com \
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ" 2>/dev/null)
  echo "    live: $T27L"
  echo "$T27L" | jq -e '.ok==true' >/dev/null && ok "live metadata fetch ok" || no "live fetch not ok"
  echo "$T27L" | jq -e '.title|length>0' >/dev/null && ok "live fetch has non-empty title" || no "live title empty"
fi

echo "=== T28: discover_feeds op returns an array (trafilatura, live) ==="
T28=$(printf '{"steps":[{"op":"navigate","url":"https://techcrunch.com"},{"op":"discover_feeds","name":"feeds","url":"https://techcrunch.com"}]}' \
  | "$SB" run --recipe - 2>/dev/null)
echo "    $T28"
echo "$T28" | jq -e '.ok==true' >/dev/null && ok "discover_feeds ran without error" || no "discover_feeds errored"
echo "$T28" | jq -e '.extracted.feeds|type=="array"' >/dev/null && ok "discover_feeds returned a list" || no "discover_feeds result not an array"

echo "=== T29: spider_crawl op returns todo+done structure (max_pages=5) ==="
T29=$(printf '{"steps":[{"op":"navigate","url":"https://example.com"},{"op":"spider_crawl","name":"result","url":"https://example.com","max_pages":5}]}' \
  | "$SB" run --recipe - 2>/dev/null)
echo "    $T29"
echo "$T29" | jq -e '.ok==true' >/dev/null && ok "spider_crawl ran without error" || no "spider_crawl errored"
echo "$T29" | jq -e '.extracted.result|has("todo") and has("done")' >/dev/null && ok "spider_crawl returned todo+done shape" || no "spider_crawl result shape wrong"

echo "=== T30: lint-dockerfile (hadolint) passes on both Dockerfiles ==="
"$SB" lint-dockerfile >/dev/null 2>/dev/null && ok "Dockerfiles pass hadolint (no violations)" || no "hadolint reported violations"

echo "=== T31: --circuit-breaker opens after 3 failures, fast-fails 4th (offline) ==="
# Use an unreachable address inside the container (--offline + non-data: URL -> always fails).
# Run 3 recipes pointing at the same host with --circuit-breaker; the 3rd should cause the
# circuit to open.  A 4th recipe then expects a circuit-breaker fast-fail WITHOUT a new
# navigate attempt (steps_run==0 and error contains "circuit-breaker").
CB_RECIPE='{"steps":[{"op":"navigate","url":"http://192.0.2.1","timeout":2000}]}'
CB_PROFILE="cb-test-$$"
# Wipe any stale CB state for this profile.
docker run --rm -v sandbox-profile:/profile --entrypoint sh "$IMG" \
  -c "rm -f /profile/${CB_PROFILE}/.cb_state.json /profile/${CB_PROFILE}/SingletonLock" >/dev/null 2>&1 || true
CB1=$(printf '%s' "$CB_RECIPE" | "$SB" run --circuit-breaker --offline --profile "$CB_PROFILE" --recipe - 2>/dev/null); echo "    cb1 (fail 1): ok=$(echo "$CB1"|jq -r '.ok') steps=$(echo "$CB1"|jq -r '.steps_run')"
CB2=$(printf '%s' "$CB_RECIPE" | "$SB" run --circuit-breaker --offline --profile "$CB_PROFILE" --recipe - 2>/dev/null); echo "    cb2 (fail 2): ok=$(echo "$CB2"|jq -r '.ok') steps=$(echo "$CB2"|jq -r '.steps_run')"
CB3=$(printf '%s' "$CB_RECIPE" | "$SB" run --circuit-breaker --offline --profile "$CB_PROFILE" --recipe - 2>/dev/null); echo "    cb3 (fail 3/open): ok=$(echo "$CB3"|jq -r '.ok') cb=$(echo "$CB3"|jq -r '._circuit_breaker|keys|length')"
echo "$CB3" | jq -e '._circuit_breaker and (._circuit_breaker|length > 0)' >/dev/null \
  && ok "circuit opened after 3rd failure (state in _circuit_breaker)" \
  || no "circuit did not open after 3 failures"
CB4=$(printf '%s' "$CB_RECIPE" | "$SB" run --circuit-breaker --offline --profile "$CB_PROFILE" --recipe - 2>/dev/null); echo "    cb4 (fast-fail): ok=$(echo "$CB4"|jq -r '.ok') steps=$(echo "$CB4"|jq -r '.steps_run')"
echo "$CB4" | jq -e '.ok==false and .steps_run==0' >/dev/null \
  && ok "4th recipe fast-failed (steps_run==0, circuit open)" \
  || no "4th recipe did not fast-fail as expected"
echo "$CB4" | jq -e '.errors[0].error|test("circuit-breaker")' >/dev/null \
  && ok "fast-fail error message contains 'circuit-breaker'" \
  || no "fast-fail error message missing 'circuit-breaker'"
# Verify the flag is a true no-op when absent (same recipe without --circuit-breaker
# succeeds normally on a data: URL, proving the proven default path is untouched).
CB_OK=$(printf '%s' '{"steps":[{"op":"navigate","url":"data:text/html,<h1>ok</h1>"},{"op":"extract_text","name":"h","selector":"h1"}]}' \
  | "$SB" run --offline --recipe - 2>/dev/null)
echo "$CB_OK" | jq -e '.extracted.h=="ok"' >/dev/null \
  && ok "default path (no --circuit-breaker) byte-identical — not affected" \
  || no "default path broken by circuit-breaker patch"
# Cleanup test profile.
docker run --rm -v sandbox-profile:/profile --entrypoint sh "$IMG" \
  -c "rm -rf /profile/${CB_PROFILE}" >/dev/null 2>&1 || true

echo "=== T32: axe op runs the accessibility audit (offline, data: URL) ==="
# A page with an alt-less image + a label-less input -> axe-core flags violations.
A11Y_HTML='<html><body><img src="x.png"><input id="q" name="q"></body></html>'
A11Y_B64=$(printf '%s' "$A11Y_HTML" | base64 | tr -d '\n')
A11Y_URL="data:text/html;base64,$A11Y_B64"
T32=$(jq -n --arg u "$A11Y_URL" '{steps:[{op:"navigate",url:$u},{op:"axe",name:"a11y"}]}' \
  | "$SB" run --offline --recipe - 2>/dev/null)
echo "    $(echo "$T32" | jq -c '.extracted.a11y.counts // .errors')"
echo "$T32" | jq -e '.ok==true' >/dev/null && ok "axe op ran without error" || no "axe op errored"
echo "$T32" | jq -e '.extracted.a11y.violations|type=="array"' >/dev/null \
  && ok "axe returned a violations array" || no "axe violations not an array"
echo "$T32" | jq -e '.extracted.a11y.counts|has("violations") and has("passes")' >/dev/null \
  && ok "axe returned pass/violation counts" || no "axe counts shape wrong"

echo "=== T33: fetch-impersonate (curl_cffi) — import wiring + live bridge fetch ==="
HTTPI=$(docker run --rm --entrypoint /opt/httpvenv/bin/python "$IMG" -c 'import curl_cffi; print("curl_cffi-import-ok")' 2>/dev/null)
echo "$HTTPI" | grep -q 'curl_cffi-import-ok' && ok "curl_cffi imports in httpvenv" || no "curl_cffi import failed in httpvenv"
T33=$("$SB" fetch-impersonate --work "$WORK" https://example.com 2>/dev/null)
echo "    $(echo "$T33" | jq -c '{ok,status,bytes,impersonate}')"
echo "$T33" | jq -e '.ok==true and .status==200' >/dev/null && ok "fetch-impersonate got HTTP 200" || no "fetch-impersonate did not return 200"
echo "$T33" | jq -e '.bytes>0' >/dev/null && ok "fetch-impersonate body has bytes" || no "fetch-impersonate body empty"

echo "=== T34: load (vegeta) — binary present + live bridge load test ==="
VEG=$(docker run --rm --entrypoint vegeta "$IMG" -version 2>/dev/null)
echo "$VEG" | grep -qiE 'version|v12\.' && ok "vegeta binary present in image" || no "vegeta binary missing"
T34=$("$SB" load --work "$WORK" --rate 5 --duration 2 https://example.com 2>/dev/null)
echo "    $(echo "$T34" | jq -c '{ok,requests,throughput,status_codes,p50:.latency_ms.p50}')"
echo "$T34" | jq -e '.ok==true' >/dev/null && ok "load ran without error" || no "load errored"
echo "$T34" | jq -e '.throughput>0' >/dev/null && ok "load reported positive throughput" || no "load throughput not positive"
echo "$T34" | jq -e '.latency_ms.p50>=0' >/dev/null && ok "load reported a p50 latency" || no "load p50 latency missing"
echo "$T34" | jq -e '.status_codes|has("200")' >/dev/null && ok "load saw HTTP 200 responses" || no "load status_codes missing 200"

echo
echo "=== WEB SANDBOX: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES PRESENT" >&2; exit 1; }
