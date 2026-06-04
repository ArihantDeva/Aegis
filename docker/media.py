#!/usr/bin/env python3
"""Sandboxed media downloader (yt-dlp).

Fetches audio/video (or only metadata/subtitles) from a URL via yt-dlp INSIDE
the container, so streams stay within the egress-controlled network boundary and
land in /work for the caller to read back.

Environment variables (set by bin/sandbox cmd_fetch_media):
  MEDIA_URL              Required. URL to download.
  MEDIA_FORMAT           Optional. "audio", "video", or "best" (default: best).
  MEDIA_WRITE_AUTO_SUBS  Optional. "1" -> pass --write-auto-subs to yt-dlp.
  MEDIA_SKIP_DOWNLOAD    Optional. "1" -> metadata + subtitles only, no A/V file.
  SANDBOX_PROXY          Optional. Proxy URL (set by --allow egress path).

Output (stdout): one JSON line
  {ok, file, url, format, subtitles_path, metadata_path, error}

Lives in /opt/mediavenv so yt-dlp's dependency set never touches the recipe runner.
"""
import json
import os
import sys

WORK_DIR = os.environ.get("WORK_DIR", "/work")


def main() -> int:
    url = os.environ.get("MEDIA_URL", "").strip()
    if not url:
        print(json.dumps({"ok": False, "error": "MEDIA_URL not set"}))
        return 2

    fmt = os.environ.get("MEDIA_FORMAT", "best").strip()
    write_auto_subs = os.environ.get("MEDIA_WRITE_AUTO_SUBS", "0") == "1"
    skip_download = os.environ.get("MEDIA_SKIP_DOWNLOAD", "0") == "1"
    proxy = os.environ.get("SANDBOX_PROXY", "").strip()

    # Format selector: "audio" picks best audio-only stream; "video" picks the
    # best combined stream; "best" lets yt-dlp choose its default (usually
    # best-combined for video sites, audio for audio-only sources).
    if fmt == "audio":
        format_sel = "bestaudio/best"
    elif fmt == "video":
        format_sel = "bestvideo+bestaudio/best"
    else:
        format_sel = "best"

    outtmpl = os.path.join(WORK_DIR, "%(title).50s.%(ext)s")

    ydl_opts: dict = {
        "outtmpl": outtmpl,
        "format": format_sel,
        "quiet": True,
        "no_warnings": True,
        # Suppress partial .part files; they clutter /work on mid-stream failures.
        "nopart": True,
        # Never load user-installed plugins from outside the venv.
        "no_load_plugins": True,
        "skip_download": skip_download,
        "writeinfojson": True,   # always write metadata JSON to /work
        "writesubtitles": True,
        "writeautomaticsub": write_auto_subs,
        "subtitleslangs": ["en"],
    }
    if proxy:
        ydl_opts["proxy"] = proxy

    try:
        import yt_dlp

        downloaded_file = None
        info_path = None
        subs_path = None

        class _FilenameCollector(yt_dlp.YoutubeDL):
            """Thin subclass that captures the final filename after pp-chain."""
            _last_filename: str = ""

            def process_info(self, info_dict: dict) -> None:  # type: ignore[override]
                super().process_info(info_dict)
                fn = info_dict.get("_filename") or info_dict.get("filepath", "")
                if fn:
                    _FilenameCollector._last_filename = fn

        with _FilenameCollector(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=not skip_download)

        if info is None:
            print(json.dumps({"ok": False, "url": url, "error": "yt-dlp returned no info"}))
            return 1

        title = info.get("title", "media")

        # Locate the written .info.json file.
        for candidate in os.listdir(WORK_DIR):
            if candidate.endswith(".info.json"):
                info_path = os.path.join(WORK_DIR, candidate)
                break

        # Locate subtitles file (.en.vtt / .en.srt / .en.ttml …).
        for candidate in os.listdir(WORK_DIR):
            if ".en." in candidate and not candidate.endswith(".info.json") and \
               not candidate.endswith(".webm") and not candidate.endswith(".mp4") and \
               not candidate.endswith(".m4a") and not candidate.endswith(".mp3"):
                subs_path = os.path.join(WORK_DIR, candidate)
                break

        # Locate downloaded media file (largest non-json, non-sub file by mtime).
        if not skip_download:
            media_exts = {".mp4", ".webm", ".mkv", ".m4a", ".mp3", ".ogg", ".flac", ".opus"}
            candidates = [
                os.path.join(WORK_DIR, f)
                for f in os.listdir(WORK_DIR)
                if os.path.splitext(f)[1].lower() in media_exts
            ]
            if candidates:
                downloaded_file = max(candidates, key=os.path.getmtime)

        result: dict = {
            "ok": True,
            "url": url,
            "title": title,
            "format": fmt,
            "file": downloaded_file,
            "subtitles_path": subs_path,
            "metadata_path": info_path,
        }
    except Exception as e:  # noqa: BLE001 - surface any yt-dlp failure as structured JSON
        print(json.dumps({"ok": False, "url": url, "error": str(e)}))
        return 1

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
