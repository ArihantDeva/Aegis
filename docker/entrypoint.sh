#!/usr/bin/env bash
# Container entrypoint. Two modes:
#   MODE=headless (default) -> no display, fastest, fully isolated.
#   MODE=observe            -> Xvfb + fluxbox + x11vnc + noVNC on :6080 so a
#                              human can WATCH the run in a browser tab, without
#                              the automation ever touching the host screen.
set -euo pipefail

if [ "${MODE:-headless}" = "observe" ]; then
  Xvfb :99 -screen 0 "${SCREEN:-1280x800x24}" -nolisten tcp &
  for _ in $(seq 1 30); do [ -e /tmp/.X11-unix/X99 ] && break; sleep 0.2; done
  fluxbox >/dev/null 2>&1 &
  x11vnc -display :99 -forever -shared -nopw -quiet -rfbport 5900 >/dev/null 2>&1 &
  websockify --web /usr/share/novnc 6080 localhost:5900 >/dev/null 2>&1 &
  export HEADLESS=0
  echo "[sandbox] observe mode: open http://localhost:${NOVNC_PORT:-6080}/vnc.html" >&2
else
  export HEADLESS=1
fi

# RUNNER=agent -> the LLM-driven browser-use agent (its own venv); default ->
# the recipe runner. Both honor the display stack above, so `agent --observe`
# is watchable at the noVNC URL just like a recipe run.
if [ "${RUNNER:-driver}" = "agent" ]; then
  exec /opt/agentvenv/bin/python /opt/agent.py "$@"
fi

# RUNNER=convert -> markitdown document->Markdown converter (its own venv). No
# browser, no display; reads CONVERT_FILE from /work and writes <stem>.md back.
if [ "${RUNNER:-driver}" = "convert" ]; then
  exec /opt/convertvenv/bin/python /opt/convert.py "$@"
fi

# RUNNER=media -> yt-dlp media downloader (its own venv). No browser, no display;
# reads MEDIA_URL + MEDIA_FORMAT + MEDIA_SKIP_DOWNLOAD + MEDIA_WRITE_AUTO_SUBS
# from env and writes A/V file / subtitles / metadata JSON into /work.
if [ "${RUNNER:-driver}" = "media" ]; then
  exec /opt/mediavenv/bin/python /opt/media.py "$@"
fi

# RUNNER=http -> curl_cffi browser-impersonation fetcher (its own venv). No
# browser, no display; reads HTTP_URL + HTTP_IMPERSONATE etc. from env and writes
# the response body + result.json into /work.
if [ "${RUNNER:-driver}" = "http" ]; then
  exec /opt/httpvenv/bin/python /opt/http_impersonate.py "$@"
fi

# RUNNER=load -> vegeta HTTP load tester. No browser, no display; reads LOAD_URL
# + LOAD_RATE + LOAD_DURATION from env, drives the in-image vegeta binary on the
# driver venv's interpreter, and writes vegeta-report.json into /work.
if [ "${RUNNER:-driver}" = "load" ]; then
  exec /opt/venv/bin/python /opt/load.py "$@"
fi

# SANDBOX_ENGINE=camoufox -> the Camoufox (undetectable Firefox) engine in its
# own venv, reading its patched Firefox + GeoIP DB from the build-time cache.
# Checked before the patchright/video branch: Camoufox owns stealth on its path.
if [ "${SANDBOX_ENGINE:-}" = "camoufox" ]; then
  export XDG_CACHE_HOME=/opt/camoufox-cache
  exec /opt/camoufoxvenv/bin/python /opt/driver.py "$@"
fi

# The recipe runner lives in two isolated venvs: the stealth engine (patchright)
# can't share the pinned-playwright driver venv, so the interpreter is picked here.
# patchright is also the only engine that can record video (the apt Chromium hangs
# on Playwright's screencast), so SANDBOX_VIDEO routes to the stealth venv too --
# driver.py then uses patchright's bundled Chromium for the recording run.
if [ "${SANDBOX_STEALTH:-0}" = "1" ] || [ "${SANDBOX_VIDEO:-0}" = "1" ]; then
  exec /opt/stealthvenv/bin/python /opt/driver.py "$@"
fi

exec /opt/venv/bin/python /opt/driver.py "$@"
