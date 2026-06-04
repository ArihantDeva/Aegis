# Aegis - off-screen, hardened computer-use

Everything that would otherwise drive the **host** screen, cursor, focus, or your
real browser runs **here** instead. Web tasks run in an ephemeral, capability-dropped
Docker container; native-macOS-app tasks run in an isolated Tart VM. The host display
is never touched and never interrupted. Aegis ships as a single CLI, `sandbox`.

The container is the security boundary: every run is unprivileged, capability-dropped,
resource-bounded, and ephemeral, with controlled egress, so automation can drive a
browser without ever reaching the host screen or the host network.

## Layout

```
sandbox/
  bin/sandbox            orchestration CLI (build / run / agent / cf-get / convert / fetch-media / fetch-impersonate / load / spider / observe / shell / vm / stop / doctor / lint-dockerfile)
  docker/
    Dockerfile           debian + system chromium + 7 isolated venvs + vegeta + axe-core + virtual-display stack
    entrypoint.sh        headless (default) | observe (Xvfb+fluxbox+x11vnc+noVNC :6080); routes driver / stealth / camoufox / agent / convert / media / http / load
    driver.py            recipe runner (JSON recipe schema) -> JSON on stdout; stealth/camoufox engines + trace/har/video + markdown/article + axe a11y audit
    agent.py             LLM-driven "give it a goal" runner (browser-use)
    convert.py           document -> Markdown converter (markitdown; PDF/Office/images, offline)
    media.py             audio/video/subtitle/metadata downloader (yt-dlp)
    http_impersonate.py  browser-fingerprint (TLS/JA3) HTTP fetcher (curl_cffi)
    load.py              HTTP load tester -> latency percentiles (vegeta)
    egress/
      Dockerfile         tinyproxy default-deny egress sidecar
      entrypoint.sh      builds the allow-list from $SANDBOX_ALLOW
  vm/tart.sh             Tart macOS-VM lifecycle (pull/clone/up/view/ssh/run/setup-agent/agent/down)
  test/fulltest.sh       exhaustive functional suite (every op, both boundaries, all capability flags)
  verify.sh              quick self-test: build + headless extract + hardening + egress-block
  README.md              this file
```

The image carries **seven isolated Python venvs** so fast-moving or conflicting
dependency sets can never regress the proven recipe runner:

| venv | holds | drives |
|------|-------|--------|
| `/opt/venv` | `playwright==1.49.0` + trafilatura + markdownify | the default recipe runner (system Chromium) + `sandbox load` |
| `/opt/stealthvenv` | patchright (+ trafilatura + markdownify) | `--stealth` and `--video` runs (patchright's own patched Chromium) |
| `/opt/camoufoxvenv` | camoufox (+ its fetched patched Firefox + GeoIP DB) | `--camoufox` runs (undetectable Firefox engine) |
| `/opt/convertvenv` | markitdown | `sandbox convert` (document -> Markdown, offline) |
| `/opt/agentvenv` | browser-use | `sandbox agent` (LLM goal runner) |
| `/opt/mediavenv` | yt-dlp | `sandbox fetch-media` (audio/video/subs/metadata) |
| `/opt/httpvenv` | curl_cffi | `sandbox fetch-impersonate` (browser TLS/JA3 fetch) |

Two non-venv tools ride alongside them: the **vegeta** static binary
(`/usr/local/bin/vegeta`, drives `sandbox load`) and the vendored **axe-core**
engine (`/opt/axe.min.js`, injected by the `axe` recipe op).

## Quick start

```bash
cd sandbox
./bin/sandbox build          # build images (once; re-run after editing docker/)
./verify.sh                  # prove it works and stays off-screen

# headless web extract
./bin/sandbox run --recipe '{"steps":[
  {"op":"navigate","url":"https://example.com"},
  {"op":"extract_text","name":"title","selector":"h1"}]}'

# watch a first-time login (host screen untouched), scoped egress
./bin/sandbox run --observe --allow github.com --recipe '{"steps":[
  {"op":"navigate","url":"https://github.com/login"},
  {"op":"sleep","ms":60000}]}'
# open http://localhost:6080/vnc.html, log in by hand; the profile volume keeps the session
```

## Capability flags (opt-in, all off by default)

Every flag is additive: pass it on `sandbox run` and the proven default path is
unchanged when you don't.

| flag | effect |
|------|--------|
| `--stealth` | swap the engine for **patchright**, a patched, undetected Playwright fork that passes Cloudflare / DataDome / Akamai / Kasada bot checks. Uses its own patched Chromium from a separate venv, so the pinned recipe runner is untouched. |
| `--camoufox` | swap the engine for **Camoufox**, an undetectable Firefox fork with C++-level fingerprint injection. A different engine family from the Chromium-based default/patchright path, so a site that fingerprints Chromium-stealth can be met with a Firefox identity instead. Same recipe schema; own venv + own `firefox/` profile namespace. Composes with `--har` / `--video` / `--allow`. |
| `--trace` | record a Playwright **trace.zip** into `/work` (open with `playwright show-trace trace.zip` for a step-by-step DOM + screenshot timeline). |
| `--har` | record a **network.har** of every request/response into `/work`. |
| `--video` | record a **.webm** screencast of the run into `/work`. Routes through the patchright engine (and its bundled Chromium): the apt system Chromium hangs on Playwright's screencast handshake, so video recording uses the same engine as `--stealth`. |
| `--readonly` | run on an **immutable root filesystem** (`--read-only` + tmpfs `/home/sandbox`); the only writable surfaces are the tmpfs mounts and the profile/work volumes. Maximum isolation. |

Two extra extraction ops turn a rendered page into clean text locally (no API):
`extract_markdown` (whole page or a `selector` -> Markdown, via markdownify) and
`extract_article` (main article body -> Markdown/text, via trafilatura). The `pdf`
op renders the page to a PDF in `/work` (Chromium headless only, so it runs on the
default engine, not under `--observe` or `--stealth`). The `axe` op injects the
vendored **axe-core** engine and runs a WCAG/accessibility audit on the current
page, returning the violation list (id, impact, help, node count) plus
pass/violation/incomplete/inapplicable counts; optional `tags` (e.g.
`["wcag2a","wcag2aa"]`) and `rules` narrow the run.

```bash
# stealth fetch behind a bot wall, with a trace + HAR for debugging
sandbox run --stealth --trace --har --recipe '{"steps":[
  {"op":"navigate","url":"https://protected.example"},
  {"op":"extract_article","name":"body"}]}'
```

## LLM "give it a goal" mode - `sandbox agent`

Describe an objective in plain language and the **browser-use** agent figures out
the clicks itself, driving an isolated Chromium in the same hardened container.
The LLM endpoint comes entirely from your environment, never the repo:

- OpenAI-compatible: `OPENAI_API_KEY` (+ optional `OPENAI_BASE_URL` for any compatible server)
- Anthropic: `ANTHROPIC_API_KEY`  -  Google: `GOOGLE_API_KEY`

```bash
export OPENAI_API_KEY=sk-...        # or ANTHROPIC_API_KEY / GOOGLE_API_KEY
sandbox agent --model gpt-4o "search Hacker News for the top Show HN today and give me its URL"
sandbox agent --observe "log into the demo site and download the latest invoice"   # watch at :6080
```

`--profile`, `--observe`, `--offline`/`--allow`, `--mem`/`--cpus`, `--readonly`,
`--max-steps` all apply. Output is one JSON line: `{"ok","goal","result"}`.

## Cloudflare-walled URLs - `sandbox cf-get`

For pages that hard-block automation, `cf-get` fetches through a **FlareSolverr**
sidecar (its own browser solves the challenge) and returns the cleared HTML +
clearance cookies:

```bash
sandbox cf-get https://heavily-protected.example
# -> JSON summary {ok,status,url,cookies,html}; full page HTML at <work>/cf-page.html
```

The sidecar is reused across calls and torn down by `sandbox stop`. (Try `--stealth`
first; it clears most walls without a second container.)

## Documents to Markdown via `sandbox convert`

Turn a local document into Markdown entirely inside the hardened container
(offline, `--network none`, no cloud API), via **markitdown**. The file's host
directory is mounted at `/work`, the `.md` is written back beside the source, and
the Markdown is also returned inline:

```bash
sandbox convert report.pdf
# -> JSON {ok,file,out,chars,markdown}; report.md written beside report.pdf
```

Handles PDF, DOCX, PPTX, XLSX, HTML, CSV, JSON, XML, EPub, and images. It runs in
its own venv with no browser and no network, so it never touches the recipe runner
or the profile volume.

## Fingerprint-true fetch via `sandbox fetch-impersonate`

A non-browser HTTP(S) client that mimics a real browser's TLS/JA3 + HTTP/2
fingerprint (via **curl_cffi**), for sites that fingerprint the transport but do
not need a rendered DOM. Far lighter than launching Chromium, far higher fidelity
than a raw `requests` call. Honors `--allow` / `--offline` like every other runner
(the TLS handshake is CONNECT-tunneled through the egress sidecar, so the
fingerprint is preserved end-to-end):

```bash
sandbox fetch-impersonate --impersonate chrome120 https://example.com
# -> JSON {ok,status,url,elapsed_ms,impersonate,bytes,content_type,body_path,headers}
#    response body written to <work>/body.{html|txt|bin}
sandbox fetch-impersonate --method POST --header 'Accept:application/json' \
  --body '{"q":1}' --allow api.example.com https://api.example.com/v1/search
```

## HTTP load testing via `sandbox load`

Fire a constant-rate request stream at a single URL (via the **vegeta** static
binary) and get back latency percentiles, throughput, success rate, and the
status-code distribution. Honors `--allow` / `--offline`:

```bash
sandbox load --rate 50 --duration 10 https://example.com
# -> JSON {ok,requests,throughput,success_rate,status_codes,
#          latency_ms:{mean,p50,p90,p95,p99,max},errors}
#    raw vegeta report written to <work>/vegeta-report.json
```

## Dockerfile linting via `sandbox lint-dockerfile`

Lint the sandbox Dockerfiles for hardening anti-patterns with **hadolint** (run in
a throw-away container; nothing is installed into the image). Rule suppressions
live in `.hadolint.yaml` at the repo root. Exit 0 = clean, 1 = violations:

```bash
sandbox lint-dockerfile
```

## Hardening (the "proper protections and strength")

Every container run gets:

- **`--cap-drop ALL`** - no Linux capabilities. (Chromium's own sandbox needs some of
  these, so it runs `--no-sandbox`; the **container** is the security boundary, not
  chromium's internal sandbox.)
- **`--security-opt no-new-privileges`** - no setuid escalation.
- **non-root** - runs as the unprivileged `sandbox` user (uid from the image).
- **`--pids-limit 512`**, **`--memory`/`--memory-swap` equal** (no swap), **`--cpus`** -
  resource caps; a runaway page can't exhaust the host.
- **`--tmpfs /tmp`** (nosuid,nodev), **`--rm`** - ephemeral; nothing persists except the
  one named profile volume.
- **isolated, per-task profiles** - a named Docker volume (`sandbox-profile`), never your
  real Chrome. `--profile NAME` (default `default`) gives each service its own subdir, so a
  Twitter session and a Gmail session keep **separate** cookie stores and never collide.
  Stale Chromium single-instance locks (left by an ungracefully-killed `--rm` container) are
  cleared automatically on the next launch, so one crash can never permanently brick a profile.
- **scoped mount** - only the `--work` dir is bind-mounted (`/work`, for screenshots).
  Nothing else of the host filesystem is visible.
- **default-deny egress** (opt-in via `--allow`) - the browser sits on an `--internal`
  Docker network with **no route to the internet**; its only path out is a tinyproxy
  sidecar that permits **only** the `$SANDBOX_ALLOW` domains (and subdomains). Everything
  else is refused. `--offline` removes egress entirely (`--network none`).
- **noVNC bound to localhost** - observe mode publishes `127.0.0.1:6080` only, never the LAN.

`verify.sh` asserts non-root, `CapEff=0`, no leftover containers, and that a
non-allowed domain is actually blocked in `--allow` mode. `test/fulltest.sh`
exercises every recipe op, both network boundaries, profile isolation, stale-lock
self-heal, and the full capability layer (stealth, the camoufox Firefox engine and
its allow-list boundary, trace/HAR/video, markdown/article extraction, the pdf op,
the axe accessibility audit, document convert, read-only rootfs, the agent runner
wiring, the per-domain circuit breaker, Dockerfile linting, the curl_cffi
fingerprint fetcher, and the vegeta load tester).

## Network modes

| flag | network | egress |
|------|---------|--------|
| (none) | bridge | full internet |
| `--offline` | none | none |
| `--allow a.com,b.com` | internal + proxy | only those domains (+subdomains) |

## Native macOS apps - Tart VM

```bash
./bin/sandbox vm pull          # ONE TIME, slow (~30GB) — do it deliberately
./bin/sandbox vm clone         # make working VM 'sandbox-macos'
./bin/sandbox vm up            # headless   (or: vm view  for its own VNC window)
./bin/sandbox vm ssh CMD       # run a command in the guest (password auth via expect)
./bin/sandbox vm run R         # scp a recipe into the guest and stage it
./bin/sandbox vm setup-agent   # install self-operating-computer in a guest venv (once)
./bin/sandbox vm agent "GOAL"  # LLM computer-use: drive the guest's real macOS apps
./bin/sandbox vm down          # delete the working VM (base image kept)
```

The guest has its **own** screen; the host's is never used. SSH uses the cirruslabs base
image's public default login (`admin`/`admin`); override with `SANDBOX_TART_PASS` for a
hardened guest. Verified end-to-end: clone, headless boot, guest IP, command + exit-code
propagation, recipe staging, hostname isolation, teardown.

**Native-app LLM computer-use** (`vm agent`) runs **self-operating-computer** inside the
guest. The LLM key comes from your env (`OPENAI_API_KEY` / `ANTHROPIC_API_KEY` /
`GOOGLE_API_KEY`), passed to the guest at runtime only and never persisted. One-time setup
is required in the guest because macOS TCC cannot be granted over SSH: run `vm setup-agent`,
then in the guest screen grant **Screen Recording + Accessibility** to Terminal once (the
agent drives the cursor via pyautogui, which needs the guest's active GUI session, so it is
launched through `launchctl asuser`).

## Recipe schema

`{"steps":[{op, ...}]}`; ops: `navigate`,
`wait_for`, `fill`, `fill_form`, `click`, `press`, `select`, `check`, `uncheck`,
`upload`, `eval`, `extract_text`, `extract_attr`, `extract_markdown`,
`extract_article`, `discover_feeds`, `discover_sitemaps`, `spider_crawl`,
`axe`, `screenshot`, `pdf`, `sleep`. Result:
`{"ok", "extracted", "steps_run", "errors"}`.

## License & notices

This project is MIT licensed (`LICENSE`). The container images bundle or pull
third-party components under their own licenses, attributed in
`THIRD_PARTY_NOTICES.md`. Security posture and vulnerability reporting are in
`SECURITY.md`. The 2026-06 four-round security and readiness audit is recorded
in `docs/security-audit-2026-06.md`.
