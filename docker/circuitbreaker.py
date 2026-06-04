"""Per-domain circuit breaker for the sandbox recipe runner.

Loaded only when SANDBOX_CIRCUIT_BREAKER=1 (--circuit-breaker flag).  The
default path (flag absent) never imports this module, so no new dependency
affects existing runs.

State is persisted to PROFILE_DIR/.cb_state.json so the open/closed status
survives across ephemeral --rm containers — the /profile named volume is
already mounted and writable by the sandbox user.

Public API consumed by driver.run():
  cb = PerDomainCircuitBreaker()
  cb.check_host(hostname)          -> raises CircuitBreakerError if open
  cb.register_success(hostname)    -> clears failure count, closes circuit
  cb.register_failure(hostname)    -> increments count; opens at fail_max
  cb.state_snapshot()              -> dict safe to embed in result JSON
  hostname_from_url(url)           -> str hostname extracted via urlparse
"""
import json
import os
import time
from urllib.parse import urlparse

import pybreaker

# State lives inside the SAME per-profile subdir Chromium uses (/profile/<name>),
# so distinct --profile values keep isolated breaker state -- and the path matches
# what callers wipe. PROFILE_DIR is the mount root; SANDBOX_PROFILE selects the
# named profile, exactly as driver.py composes its user_data_dir.
_PROFILE_ROOT = os.environ.get("PROFILE_DIR", "/profile")
_PROFILE_NAME = os.environ.get("SANDBOX_PROFILE", "default")
_STATE_PATH = os.path.join(_PROFILE_ROOT, _PROFILE_NAME, ".cb_state.json")
# Defaults: 3 consecutive navigate failures open the circuit for 300 s.
# Override at container launch via CB_FAIL_MAX / CB_RESET_TIMEOUT env vars.
_FAIL_MAX = int(os.environ.get("CB_FAIL_MAX", "3"))
_RESET_TIMEOUT = int(os.environ.get("CB_RESET_TIMEOUT", "300"))


class PerDomainCircuitBreaker:
    """Per-hostname circuit breaker backed by pybreaker.

    Keyed by hostname (e.g. "example.com") so api.example.com and
    cdn.example.com share one breaker — the intended behaviour for a single
    logical target that is globally down or blocking.

    Persistence: open-until timestamps are written to _STATE_PATH on every
    transition.  On load, any timestamp still in the future means the circuit
    is still open; an elapsed timestamp triggers a half-open probe attempt
    (the next navigate is allowed through as a canary).
    """

    def __init__(self) -> None:
        self._open_until: dict = {}
        self._fail_counts: dict = {}
        self._load_state()

    # ------------------------------------------------------------------
    # state persistence
    # ------------------------------------------------------------------

    def _load_state(self) -> None:
        try:
            if os.path.exists(_STATE_PATH):
                with open(_STATE_PATH, "r", encoding="utf-8") as fh:
                    data = json.load(fh)
                # New schema nests both maps; tolerate the legacy flat schema
                # (a bare hostname->open_until dict) so old state files still load.
                if isinstance(data, dict) and "open_until" in data:
                    self._open_until = data.get("open_until", {})
                    self._fail_counts = data.get("fail_counts", {})
                else:
                    self._open_until = data or {}
                    self._fail_counts = {}
        except Exception:  # noqa: BLE001
            self._open_until = {}
            self._fail_counts = {}

    def _save_state(self) -> None:
        try:
            os.makedirs(os.path.dirname(_STATE_PATH), exist_ok=True)
            with open(_STATE_PATH, "w", encoding="utf-8") as fh:
                json.dump({"open_until": self._open_until,
                           "fail_counts": self._fail_counts}, fh)
        except Exception:  # noqa: BLE001
            pass  # best-effort; failure here does not abort the recipe

    # ------------------------------------------------------------------
    # public API
    # ------------------------------------------------------------------

    def check_host(self, hostname: str) -> None:
        """Raise CircuitBreakerError if the circuit for hostname is open.

        If the cooldown window has elapsed, the entry is cleared and a half-open
        probe is silently allowed through (the caller proceeds normally).
        """
        until = self._open_until.get(hostname, 0)
        if not until:
            return
        if time.time() < until:
            raise pybreaker.CircuitBreakerError(
                f"circuit open for {hostname!r} — "
                f"cooldown expires in {int(until - time.time())}s"
            )
        # Cooldown elapsed: allow a probe and reset state.
        del self._open_until[hostname]
        self._fail_counts.pop(hostname, None)
        self._save_state()

    def register_success(self, hostname: str) -> None:
        """Clear failure state for hostname and close its circuit."""
        changed = hostname in self._open_until or hostname in self._fail_counts
        self._open_until.pop(hostname, None)
        self._fail_counts.pop(hostname, None)
        if changed:
            self._save_state()

    def register_failure(self, hostname: str) -> None:
        """Record one navigation failure; open the circuit when fail_max is hit.

        The failure count is persisted (not just the open timestamp) so that
        consecutive failures accumulate across separate ephemeral --rm runs --
        each run registers one navigate failure, and the Nth run trips the
        circuit. An in-memory pybreaker object cannot do this: it is recreated
        empty on every container start, so the count would never grow past 1.
        """
        count = self._fail_counts.get(hostname, 0) + 1
        if count >= _FAIL_MAX:
            self._open_until[hostname] = time.time() + _RESET_TIMEOUT
            self._fail_counts.pop(hostname, None)
        else:
            self._fail_counts[hostname] = count
        self._save_state()

    def state_snapshot(self) -> dict:
        """Return a JSON-safe summary suitable for the result _circuit_breaker key."""
        now = time.time()
        return {
            h: {"open_until": int(t), "ttl_secs": max(0, int(t - now))}
            for h, t in self._open_until.items()
        }


def hostname_from_url(url: str) -> str:
    """Extract the hostname from a URL string.  Falls back to the raw URL."""
    try:
        return urlparse(url).hostname or url
    except Exception:  # noqa: BLE001
        return url
