#!/usr/bin/env bash
# Build a tinyproxy config that default-denies and allows only $SANDBOX_ALLOW.
set -euo pipefail

CONF=/tmp/tinyproxy.conf
FILTER=/tmp/tinyproxy.filter

: > "$FILTER"
IFS=',' read -ra DOMAINS <<< "${SANDBOX_ALLOW:-}"
for d in "${DOMAINS[@]}"; do
  d="$(echo "$d" | xargs)"   # trim
  [ -z "$d" ] && continue
  # Fail CLOSED on anything that is not a valid hostname (letters, digits, dot,
  # hyphen). A value carrying regex metacharacters (e.g. "example.com.*") would
  # otherwise widen the filter into an allow-everything pattern, so drop it.
  if [[ ! "$d" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "[egress] WARNING: ignoring invalid allow-list entry: $d" >&2
    continue
  fi
  # Anchor to host suffix: allow the domain and its subdomains. Escape every
  # regex metacharacter (after validation only . and - remain) so the host is
  # matched literally, never as a pattern.
  printf '(^|\\.)%s$\n' "$(printf '%s' "$d" | sed 's/[^A-Za-z0-9]/\\&/g')" >> "$FILTER"
done

# No User/Group privilege-drop: the container runs with --cap-drop ALL, so
# tinyproxy (started as root) lacks CAP_SETGID/CAP_SETUID to drop privileges and
# would exit. The container itself is the isolation boundary, so staying as the
# container's root is fine and keeps the proxy actually running.
cat > "$CONF" <<EOF
Port 8888
Listen 0.0.0.0
Timeout 600
FilterDefaultDeny Yes
Filter "$FILTER"
FilterExtended On
FilterCaseSensitive Off
FilterURLs Off
DisableViaHeader Yes
ConnectPort 443
ConnectPort 563
EOF

echo "[egress] allow-list: ${SANDBOX_ALLOW:-<empty: all denied>}" >&2
exec tinyproxy -d -c "$CONF"
