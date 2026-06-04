#!/usr/bin/env python3
"""Sandboxed recipe runner.

Runs a JSON recipe INSIDE the container against an isolated Chromium + isolated
profile. Recipe in (file,
inline JSON, or stdin via "-"), result JSON out on stdout, screenshots to /work.

Supported ops: navigate, set_cookies, wait_for, fill, fill_form, click, press,
select, check, uncheck, upload, eval, extract_text, extract_attr,
extract_markdown, extract_article, discover_feeds, discover_sitemaps,
spider_crawl, axe, screenshot, pdf, sleep.

Env switches (set by bin/sandbox flags): SANDBOX_STEALTH (patchright engine),
SANDBOX_ENGINE=camoufox (undetectable-Firefox engine),
SANDBOX_TRACE / SANDBOX_HAR / SANDBOX_VIDEO (observability artifacts to /work),
SANDBOX_CIRCUIT_BREAKER (per-domain circuit breaker via pybreaker).
"""
import argparse
import glob
import json
import os
import sys
from contextlib import contextmanager

# Stealth mode swaps the engine for patchright (a patched, undetected Playwright
# fork) which passes Cloudflare/DataDome/Akamai/Kasada. It is a true drop-in: the
# same sync API, so only the import changes. Off by default — the proven path uses
# stock Playwright against the system Chromium.
STEALTH = os.environ.get("SANDBOX_STEALTH", "0") == "1"
# Video recording also forces patchright: Playwright's screencast handshake hangs
# at launch with the debian apt Chromium (in headless AND headed/Xvfb), but
# patchright's bundled, Playwright-built Chromium records cleanly. So --video runs
# on patchright even when stealth is off. (trace/har work on the system Chromium
# and do NOT force this, so the proven default path is untouched without --video.)
VIDEO = os.environ.get("SANDBOX_VIDEO", "0") == "1"   # -> *.webm
# Camoufox is an undetectable Firefox fork (daijro, MPL-2.0) with C++-level
# fingerprint injection -- a different engine FAMILY from the Chromium-based
# default/patchright path, so a site that fingerprints Chromium-stealth can be
# approached with a Firefox identity instead. It selects its own venv (via the
# entrypoint) and its own launch path in _launch() below. It wraps Playwright,
# so Playwright's sync API + TimeoutError import here too. Camoufox owns stealth
# on its path, so patchright is never engaged alongside it.
CAMOUFOX = os.environ.get("SANDBOX_ENGINE", "") == "camoufox"
USE_PATCHRIGHT = (STEALTH or VIDEO) and not CAMOUFOX
if CAMOUFOX:
    from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout
elif USE_PATCHRIGHT:
    from patchright.sync_api import sync_playwright, TimeoutError as PWTimeout
else:
    from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

# Each named profile lives in its own subdir so distinct sandboxed services
# (e.g. a Twitter session vs a Gmail session) keep isolated, persistent login
# state and never share a cookie store. SANDBOX_PROFILE selects which one.
_PROFILE_ROOT = os.environ.get("PROFILE_DIR", "/profile")
_PROFILE_NAME = os.environ.get("SANDBOX_PROFILE", "default")
# Firefox (Camoufox) and Chromium profile layouts are incompatible, so the
# Camoufox engine keeps its profiles under a separate "firefox/" namespace and
# never shares a cookie store with a Chromium run of the same --profile name.
if CAMOUFOX:
    PROFILE_DIR = os.path.join(_PROFILE_ROOT, "firefox", _PROFILE_NAME)
else:
    PROFILE_DIR = os.path.join(_PROFILE_ROOT, _PROFILE_NAME)
WORK_DIR = os.environ.get("WORK_DIR", "/work")
CHROMIUM_BIN = os.environ.get("CHROMIUM_BIN", "/usr/bin/chromium")
HEADLESS = os.environ.get("HEADLESS", "1") != "0"
DEFAULT_TIMEOUT_MS = int(os.environ.get("DEFAULT_TIMEOUT_MS", "20000"))

# Observability (opt-in; all land in WORK_DIR so they come back to the host).
# VIDEO is defined above (it selects the engine); trace/har are engine-agnostic.
TRACE = os.environ.get("SANDBOX_TRACE", "0") == "1"   # -> trace.zip (playwright show-trace)
HAR = os.environ.get("SANDBOX_HAR", "0") == "1"       # -> network.har

# Circuit breaker: off by default.  When enabled, per-hostname pybreaker state
# opens the circuit after CB_FAIL_MAX (default 3) consecutive navigate failures
# and fast-fails subsequent recipes for CB_RESET_TIMEOUT (default 300 s).
# Imported lazily so the default path never touches pybreaker.
CIRCUIT_BREAKER = os.environ.get("SANDBOX_CIRCUIT_BREAKER", "0") == "1"
if CIRCUIT_BREAKER:
    import circuitbreaker as _cb_mod
    from pybreaker import CircuitBreakerError as _CBError
else:
    _cb_mod = None  # type: ignore[assignment]
    _CBError = None  # type: ignore[assignment]


def _load_recipe(spec: str) -> dict:
    if spec == "-":
        return json.loads(sys.stdin.read())
    if os.path.exists(spec):
        with open(spec, "r", encoding="utf-8") as fh:
            return json.load(fh)
    return json.loads(spec)


def _resolve_shot(path: str) -> str:
    if not path:
        path = "screenshot.png"
    if not os.path.isabs(path):
        path = os.path.join(WORK_DIR, path)
    # Confine screenshots to the scoped work dir; never let a recipe write elsewhere.
    real = os.path.realpath(path)
    if os.path.commonpath([real, os.path.realpath(WORK_DIR)]) != os.path.realpath(WORK_DIR):
        real = os.path.join(WORK_DIR, os.path.basename(path))
    return real


def _prepare_profile() -> None:
    """Ensure the profile dir exists and clear stale single-instance locks.

    Containers are ephemeral (--rm) and may be killed mid-run (timeout, OOM,
    docker kill). Chromium then leaves a SingletonLock symlink keyed to the dead
    container's hostname+pid. Because every container gets a new hostname,
    Chromium's own staleness check sees "another computer" and refuses to launch
    for ALL future runs — permanently bricking the persistent profile. Since a
    profile is only ever used by one container at a time, any lock we find here
    is stale by definition, so it is safe to remove before launch.
    """
    os.makedirs(PROFILE_DIR, exist_ok=True)
    # Chromium uses Singleton* locks; Firefox/Camoufox uses lock + .parentlock.
    # The other engine's names never exist in a given profile, so clearing both
    # sets is a harmless no-op and keeps the self-heal engine-agnostic.
    for name in ("SingletonLock", "SingletonCookie", "SingletonSocket", "lock", ".parentlock"):
        for path in glob.glob(os.path.join(PROFILE_DIR, name)):
            try:
                os.unlink(path)
            except OSError:
                pass


@contextmanager
def _launch():
    """Launch the selected engine's persistent context and yield it.

    Three engines share one recipe loop: stock Playwright Chromium (default),
    patchright's patched Chromium (--stealth / --video), and Camoufox's
    undetectable Firefox (--camoufox). Each yields a Playwright BrowserContext,
    so run()'s step loop below is identical regardless of which engine launched.
    """
    proxy = os.environ.get("SANDBOX_PROXY")  # e.g. http://sandbox-proxy:8888 in allowlist mode

    if CAMOUFOX:
        # Camoufox wraps Playwright but launches through its own context manager;
        # persistent_context=True + user_data_dir yields a BrowserContext. "All
        # Playwright Firefox launch options are accepted", so proxy / HAR / video
        # pass straight through. Firefox needs no --no-sandbox (no setuid sandbox
        # like Chromium's). We deliberately do NOT enable camoufox geoip=True: its
        # locale/timezone matching first calls api.ipify.org THROUGH the proxy to
        # discover the exit IP, which the --allow egress allow-list refuses (403
        # Filtered) -- and reaching ipify at all would itself breach the boundary
        # the user asserted with --allow. The egress boundary wins over fingerprint
        # geo-consistency; the Firefox traffic still routes through the proxy.
        from camoufox.sync_api import Camoufox
        cf_kwargs = dict(
            headless=HEADLESS,
            persistent_context=True,
            user_data_dir=PROFILE_DIR,
            humanize=True,
        )
        if proxy:
            cf_kwargs["proxy"] = {"server": proxy}
        if HAR:
            cf_kwargs["record_har_path"] = os.path.join(WORK_DIR, "network.har")
        if VIDEO:
            cf_kwargs["record_video_dir"] = WORK_DIR
        with Camoufox(**cf_kwargs) as ctx:
            yield ctx
        return

    if USE_PATCHRIGHT:
        # Let patchright own the arg set (it manages the anti-detection flags
        # itself and warns against extra ones / custom UA). --no-sandbox stays:
        # the container drops the caps chromium's own sandbox needs, and the
        # container is the real boundary. Use patchright's bundled patched
        # Chromium (executable_path=None), not the system one. This path also
        # serves --video (system Chromium can't record), not just --stealth.
        chromium_args = ["--no-sandbox", "--disable-dev-shm-usage"]
    else:
        chromium_args = [
            "--no-sandbox",  # the CONTAINER is the sandbox boundary; chromium's own sandbox needs caps we drop
            "--disable-dev-shm-usage",
            "--disable-gpu",
            "--no-first-run",
            "--no-default-browser-check",
        ]
    if proxy:
        chromium_args.append(f"--proxy-server={proxy}")

    ctx_kwargs = dict(
        user_data_dir=PROFILE_DIR,
        headless=HEADLESS,
        args=chromium_args,
    )
    if not USE_PATCHRIGHT:
        ctx_kwargs["executable_path"] = CHROMIUM_BIN
        ctx_kwargs["ignore_default_args"] = ["--enable-automation"]
    if HAR:
        ctx_kwargs["record_har_path"] = os.path.join(WORK_DIR, "network.har")
    if VIDEO:
        ctx_kwargs["record_video_dir"] = WORK_DIR

    with sync_playwright() as p:
        yield p.chromium.launch_persistent_context(**ctx_kwargs)


def run(recipe: dict) -> dict:
    steps = recipe.get("steps", [])
    extracted: dict = {}
    errors: list = []
    steps_run = 0

    _prepare_profile()
    _breaker = _cb_mod.PerDomainCircuitBreaker() if CIRCUIT_BREAKER else None

    with _launch() as ctx:
        if TRACE:
            ctx.tracing.start(screenshots=True, snapshots=True, sources=True)
        ctx.set_default_timeout(DEFAULT_TIMEOUT_MS)
        page = ctx.pages[0] if ctx.pages else ctx.new_page()

        for i, step in enumerate(steps):
            op = step.get("op")
            timeout = step.get("timeout", DEFAULT_TIMEOUT_MS)
            try:
                if op == "navigate":
                    _host = _cb_mod.hostname_from_url(step["url"]) if _breaker else None
                    if _breaker:
                        try:
                            _breaker.check_host(_host)
                        except _CBError as _e:
                            errors.append({"step": i, "op": op, "error": f"circuit-breaker: {_e}"})
                            break
                    try:
                        page.goto(step["url"], timeout=timeout, wait_until=step.get("wait_until", "load"))
                        if _breaker:
                            _breaker.register_success(_host)
                    except Exception as _nav_e:
                        if _breaker:
                            _breaker.register_failure(_host)
                        raise
                elif op == "set_cookies":
                    # Inject auth cookies (e.g. a seeded session) into the
                    # context so headless runs are logged in without a manual
                    # --observe login. Each entry needs name/value plus either
                    # url or domain+path (Playwright add_cookies contract).
                    ctx.add_cookies(step["cookies"])
                elif op == "wait_for":
                    if "url" in step:
                        page.wait_for_url(step["url"], timeout=timeout)
                    else:
                        page.wait_for_selector(step["selector"], timeout=timeout, state=step.get("state", "visible"))
                elif op == "fill":
                    page.fill(step["selector"], step.get("text", ""), timeout=timeout)
                elif op == "fill_form":
                    for sel, val in step.get("fields", {}).items():
                        page.fill(sel, val, timeout=timeout)
                elif op == "click":
                    page.click(step["selector"], timeout=timeout)
                elif op == "press":
                    page.press(step.get("selector", "body"), step["key"], timeout=timeout)
                elif op == "select":
                    page.select_option(step["selector"], step.get("value"), timeout=timeout)
                elif op == "check":
                    page.check(step["selector"], timeout=timeout)
                elif op == "uncheck":
                    page.uncheck(step["selector"], timeout=timeout)
                elif op == "upload":
                    page.set_input_files(step["selector"], step["files"], timeout=timeout)
                elif op == "eval":
                    extracted[step.get("name", f"eval_{i}")] = page.evaluate(step["script"])
                elif op == "extract_text":
                    extracted[step.get("name", f"text_{i}")] = page.inner_text(step["selector"], timeout=timeout)
                elif op == "extract_attr":
                    extracted[step.get("name", f"attr_{i}")] = page.get_attribute(
                        step["selector"], step["attr"], timeout=timeout
                    )
                elif op == "extract_markdown":
                    # Full rendered page -> markdown (markdownify, pure-local).
                    from markdownify import markdownify as _md
                    sel = step.get("selector")
                    html = page.inner_html(sel, timeout=timeout) if sel else page.content()
                    extracted[step.get("name", f"md_{i}")] = _md(html, heading_style="ATX")
                elif op == "extract_article":
                    # Main article content -> clean markdown/text (trafilatura, pure-local).
                    import trafilatura
                    extracted[step.get("name", f"article_{i}")] = trafilatura.extract(
                        page.content(), output_format=step.get("format", "markdown"), url=page.url
                    ) or ""
                elif op == "discover_feeds":
                    # Discover RSS/Atom feed URLs for a domain (trafilatura, makes HTTP requests).
                    from trafilatura.feeds import find_feed_urls
                    url = step.get("url") or page.url
                    extracted[step.get("name", f"feeds_{i}")] = find_feed_urls(url)
                elif op == "discover_sitemaps":
                    # Enumerate URLs from a site's sitemaps (trafilatura, makes HTTP requests).
                    from trafilatura.sitemaps import sitemap_search
                    url = step.get("url") or page.url
                    extracted[step.get("name", f"sitemap_{i}")] = sitemap_search(url)
                elif op == "spider_crawl":
                    # Focused crawl: return (todo, done) URL lists up to max_seen_urls pages.
                    from trafilatura.spider import focused_crawler
                    url = step.get("url") or page.url
                    max_seen = int(step.get("max_pages", 50))
                    todo, done = focused_crawler(url, max_seen_urls=max_seen)
                    extracted[step.get("name", f"spider_{i}")] = {"todo": list(todo), "done": list(done)}
                elif op == "axe":
                    # WCAG/accessibility audit: inject the vendored axe-core engine
                    # and run axe.run() on the current page. Returns the violation
                    # list (trimmed) plus pass/incomplete/inapplicable counts.
                    # Optional step["tags"] (e.g. ["wcag2a","wcag2aa"]) and
                    # step["rules"] narrow the run; omitted -> axe defaults.
                    with open("/opt/axe.min.js", encoding="utf-8") as _axe_fh:
                        page.evaluate(_axe_fh.read())
                    _axe_opts = {}
                    if step.get("tags"):
                        _axe_opts["runOnly"] = {"type": "tag", "values": step["tags"]}
                    if step.get("rules"):
                        _axe_opts["rules"] = step["rules"]
                    _axe_res = page.evaluate(
                        """(opts) => new Promise((resolve, reject) => {
                            try {
                                axe.run(document, opts || {}, (err, res) => {
                                    if (err) { reject(String(err)); return; }
                                    resolve({
                                        url: document.location.href,
                                        violations: res.violations.map(v => ({
                                            id: v.id, impact: v.impact, help: v.help,
                                            helpUrl: v.helpUrl, nodes: v.nodes.length
                                        })),
                                        counts: {
                                            violations: res.violations.length,
                                            passes: res.passes.length,
                                            incomplete: res.incomplete.length,
                                            inapplicable: res.inapplicable.length
                                        }
                                    });
                                });
                            } catch (e) { reject(String(e)); }
                        })""",
                        _axe_opts,
                    )
                    extracted[step.get("name", f"axe_{i}")] = _axe_res
                elif op == "screenshot":
                    dest = _resolve_shot(step.get("path", f"step_{i}.png"))
                    page.screenshot(path=dest, full_page=step.get("full_page", False))
                    extracted.setdefault("_screenshots", []).append(dest)
                elif op == "pdf":
                    # Render the page to PDF in /work. Chromium-headless only:
                    # page.pdf() is unavailable in headed/observe and patchright
                    # runs and surfaces there as a structured error (caught below).
                    dest = _resolve_shot(step.get("path", f"page_{i}.pdf"))
                    page.pdf(
                        path=dest,
                        format=step.get("format", "A4"),
                        landscape=step.get("landscape", False),
                        print_background=step.get("print_background", True),
                    )
                    extracted.setdefault("_pdfs", []).append(dest)
                elif op == "sleep":
                    page.wait_for_timeout(int(step.get("ms", 1000)))
                else:
                    raise ValueError(f"unknown op: {op!r}")
                steps_run += 1
            except PWTimeout as e:
                errors.append({"step": i, "op": op, "error": f"timeout: {e}"})
                break
            except Exception as e:  # noqa: BLE001 - surface any op failure as a structured error
                errors.append({"step": i, "op": op, "error": str(e)})
                break

        if TRACE:
            try:
                ctx.tracing.stop(path=os.path.join(WORK_DIR, "trace.zip"))
                extracted.setdefault("_artifacts", {})["trace"] = os.path.join(WORK_DIR, "trace.zip")
            except Exception:  # noqa: BLE001
                pass
        if VIDEO:
            try:
                extracted.setdefault("_artifacts", {})["video"] = page.video.path()
            except Exception:  # noqa: BLE001
                pass
        if HAR:
            extracted.setdefault("_artifacts", {})["har"] = os.path.join(WORK_DIR, "network.har")

        try:
            ctx.close()  # flushes HAR + finalizes video
        except Exception:  # noqa: BLE001
            pass

    result: dict = {"ok": not errors, "extracted": extracted, "steps_run": steps_run, "errors": errors}
    if _breaker:
        result["_circuit_breaker"] = _breaker.state_snapshot()
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--recipe", required=True, help="path, inline JSON, or '-' for stdin")
    args = ap.parse_args()
    try:
        recipe = _load_recipe(args.recipe)
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"ok": False, "errors": [{"error": f"bad recipe: {e}"}]}))
        return 2
    result = run(recipe)
    print(json.dumps(result))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
