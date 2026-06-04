# Sandboxed computer-use browser image.
# Self-contained: a recipe goes in (stdin/file), JSON comes out (stdout),
# screenshots land in /work. Never touches the host screen or the user's Chrome.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:99 \
    PROFILE_DIR=/profile \
    WORK_DIR=/work \
    CHROMIUM_BIN=/usr/bin/chromium \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    PATH="/opt/venv/bin:/usr/local/bin:/usr/bin:/bin"

# System Chromium + a virtual display stack (for observe mode) + python.
# No bundled Playwright browser download — we drive the apt Chromium directly.
RUN apt-get update && apt-get install -y --no-install-recommends \
      chromium \
      fonts-liberation fonts-unifont ca-certificates \
      xvfb x11vnc fluxbox \
      novnc websockify \
      python3 python3-venv \
      passwd \
      curl \
      tini \
 && rm -rf /var/lib/apt/lists/*

# Driver venv: the proven recipe runner. Playwright (pinned) drives the system
# Chromium; trafilatura + markdownify turn pages into clean article/markdown text.
# trafilatura imports lxml.html.clean, which lxml 5.x split into a separate
# package, so lxml_html_clean must be installed explicitly or the import fails.
RUN python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir \
      "playwright==1.49.0" trafilatura markdownify lxml_html_clean pybreaker

# Stealth venv: patchright (a patched, undetected Playwright fork that passes
# Cloudflare/DataDome/Akamai/Kasada) gets its OWN venv — its version tracks a
# matching playwright release and would fight the pinned 1.49.0 if co-installed.
# It ships its own patched Chromium (downloaded to the shared browsers path) and
# carries the same extraction deps so stealth runs can still produce markdown.
RUN python3 -m venv /opt/stealthvenv \
 && /opt/stealthvenv/bin/pip install --no-cache-dir \
      patchright trafilatura markdownify lxml_html_clean \
 && /opt/stealthvenv/bin/patchright install chromium

# Agent venv: browser-use (LLM-driven "give it a goal" mode), fully isolated from
# the driver venv so its heavier, faster-moving dependency set can never regress
# the recipe runner. browser-use 0.12.x has NO playwright dependency -- it drives
# Chromium directly over CDP (via cdp-use), so there is no `playwright install`
# step here. It reuses the SYSTEM chromium already apt-installed above; agent.py
# points it there with executable_path=/usr/bin/chromium.
RUN python3 -m venv /opt/agentvenv \
 && /opt/agentvenv/bin/pip install --no-cache-dir browser-use

# Convert venv: markitdown (Microsoft, MIT) turns documents into Markdown --
# PDF / DOCX / PPTX / XLSX / HTML / CSV / JSON / XML / EPub / images -- entirely
# offline for the built-in converters. Isolated in its own venv so its large
# dependency set never touches the recipe runner. Scoped extras keep it lean:
# pdf,docx,pptx,xlsx only (no audio/youtube/azure document-intelligence deps).
RUN python3 -m venv /opt/convertvenv \
 && /opt/convertvenv/bin/pip install --no-cache-dir "markitdown[pdf,docx,pptx,xlsx]"

# Camoufox venv: an undetectable Firefox fork (daijro, MPL-2.0) with C++-level
# fingerprint injection -- a DIFFERENT anti-detection surface from the patchright
# Chromium engine. Playwright-compatible API. Its patched Firefox (~1.2GB) + the
# GeoIP DB are fetched at BUILD time into a shared, world-readable cache under
# /opt (XDG_CACHE_HOME) so --camoufox runs work fully offline and survive
# --readonly -- a tmpfs-masked /home would otherwise hide a ~/.cache install.
# Fully isolated venv: never co-resolves with, nor regresses, the recipe runner.
RUN python3 -m venv /opt/camoufoxvenv \
 && /opt/camoufoxvenv/bin/pip install --no-cache-dir "camoufox[geoip]" \
 && XDG_CACHE_HOME=/opt/camoufox-cache /opt/camoufoxvenv/bin/python -m camoufox fetch

# Unprivileged runtime user; isolated profile + scoped work dir.
# useradd lives in /usr/sbin, which our ENV PATH override drops — call it by full path.
RUN /usr/sbin/useradd -ms /bin/bash sandbox \
 && mkdir -p /profile /work \
 && chown -R sandbox:sandbox /profile /work

# Media venv: yt-dlp (Unlicense) fetches audio/video/subtitles/metadata from
# thousands of sites entirely inside the egress-controlled sandbox boundary.
# Own venv so its dependency set (brotli, certifi, mutagen, pycryptodomex, etc.)
# never touches the recipe runner or any other engine. No browser download needed:
# yt-dlp is a pure CLI + library that drives HTTP(S) streams, not a headless browser.
RUN python3 -m venv /opt/mediavenv \
 && /opt/mediavenv/bin/pip install --no-cache-dir "yt-dlp>=2024.10.0"

# From here down, RUNs verify downloads through a pipe (... | sha256sum -c -).
# /bin/sh (dash) has no `pipefail`, so a curl that failed mid-pipe could be
# masked; switch to bash with pipefail so any broken fetch fails the build.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# axe-core (Deque, MPL-2.0): the industry-standard WCAG/accessibility audit
# engine, vendored as a single self-contained JS file. The `axe` recipe op
# injects it into the page and runs axe.run(); no venv, no network at run time --
# the build-time download is the only fetch, so audits work fully offline.
RUN curl -fsSL "https://unpkg.com/axe-core@4.12.0/axe.min.js" -o /opt/axe.min.js \
 && echo "a0afc408abecbe06ff7675033e7ea2c4046618162167aaa4ce1030b10963dece  /opt/axe.min.js" | sha256sum -c -

# vegeta (tsenart, MIT): a constant-rate HTTP load tester, shipped as a single
# static Go binary. Arch-aware so the image builds on both arm64 and amd64 hosts.
# Drives the `load` runner; honors SANDBOX_PROXY so --allow egress still applies.
RUN ARCH="$(dpkg --print-architecture)" \
 && case "$ARCH" in \
      arm64) VEGETA_SHA="950381173a5575e25e8e086f36fc03bf65d61a2433329b48e41e1cb5e4133bba" ;; \
      amd64) VEGETA_SHA="e8759ce45c14e18374bdccd3ba6068197bc3a9f9b7e484db3837f701b9d12e61" ;; \
      *) echo "unsupported arch for vegeta: $ARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /tmp/vegeta.tar.gz "https://github.com/tsenart/vegeta/releases/download/v12.13.0/vegeta_12.13.0_linux_${ARCH}.tar.gz" \
 && echo "${VEGETA_SHA}  /tmp/vegeta.tar.gz" | sha256sum -c - \
 && tar -xz -C /usr/local/bin -f /tmp/vegeta.tar.gz vegeta \
 && rm -f /tmp/vegeta.tar.gz \
 && chmod 755 /usr/local/bin/vegeta

# HTTP-impersonation venv: curl_cffi (MIT) mimics a real browser's TLS/JA3 +
# HTTP/2 fingerprint without launching Chromium -- a lightweight fetch tier for
# transport-fingerprinting sites that don't need a rendered DOM. Own venv so its
# native curl-impersonate binding never touches the recipe runner.
RUN python3 -m venv /opt/httpvenv \
 && /opt/httpvenv/bin/pip install --no-cache-dir "curl_cffi>=0.7"

COPY circuitbreaker.py /opt/circuitbreaker.py
COPY driver.py /opt/driver.py
COPY agent.py /opt/agent.py
COPY convert.py /opt/convert.py
COPY media.py /opt/media.py
COPY http_impersonate.py /opt/http_impersonate.py
COPY load.py /opt/load.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
 && chmod -R a+rX /opt   # venvs + downloaded browsers readable by the sandbox user

LABEL org.opencontainers.image.title="claude-sandbox-browser" \
      org.opencontainers.image.description="Hardened, capability-dropped headless browser and computer-use sandbox: recipe-driven Playwright/patchright/camoufox with egress allow-listing and resource caps." \
      org.opencontainers.image.base.name="debian:bookworm-slim"

USER sandbox
WORKDIR /home/sandbox
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]
