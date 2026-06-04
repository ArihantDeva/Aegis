#!/usr/bin/env bash
# tart.sh — isolated macOS guest for native-app computer-use.
#
# When a task needs a real macOS app (not a browser), it runs inside a Tart VM,
# never on the host. The guest has its own screen, its own apps, its own logins.
# You drive it over VNC/SSH; the host display and focus are never touched.
#
# Subcommands:
#   tart.sh pull            Download the base macOS image (~30GB; do this once, ahead of time)
#   tart.sh clone           Create the working VM 'sandbox-macos' from the base
#   tart.sh up              Start the VM headless (no host window)
#   tart.sh view            Start the VM with its own VNC window you can watch
#   tart.sh ip              Print the guest IP
#   tart.sh ssh [cmd...]    SSH into the guest (user admin)
#   tart.sh run <recipe>    Copy a host computer-use recipe in and run it in-guest
#   tart.sh setup-agent     Install self-operating-computer in a guest venv (once)
#   tart.sh agent "<goal>"  LLM computer-use: drive the guest's real macOS apps
#   tart.sh stop            Stop the VM
#   tart.sh down            Stop and delete the working VM (base image kept)
#   tart.sh status          Show VM + image state
#
# The 'agent' mode needs an LLM key in the CALLER's env (OPENAI_API_KEY /
# ANTHROPIC_API_KEY / GOOGLE_API_KEY). The key is passed to the guest at runtime
# only — never written to the repo or persisted on the guest disk.
#
# The base image is large and the pull is slow — run `tart.sh pull` deliberately,
# not as part of any automated path. Everything else is fast once it's local.
set -euo pipefail

BASE_IMAGE="${SANDBOX_TART_BASE:-ghcr.io/cirruslabs/macos-sequoia-base:latest}"
VM="${SANDBOX_TART_VM:-sandbox-macos}"
GUEST_USER="${SANDBOX_TART_USER:-admin}"
# Public, documented default credential of the cirruslabs base image (admin/admin).
# Not a real secret; override with SANDBOX_TART_PASS for a hardened guest.
GUEST_PASS="${SANDBOX_TART_PASS:-admin}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"

die(){ echo "tart.sh: $*" >&2; exit 1; }
have_tart(){ command -v tart >/dev/null 2>&1 || die "tart not installed. brew install cirruslabs/cli/tart"; }
have_expect(){ command -v expect >/dev/null 2>&1 || die "expect not found — needed for password SSH into the guest"; }

guest_ip(){ tart ip "$VM" 2>/dev/null; }

# Single-quote a string for safe embedding in the remote shell command.
shq(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Non-interactive SSH into the password-auth guest via expect.
# Propagates the guest command's real exit status back to the caller.
guest_ssh(){
  have_expect
  local ip="$1"; shift
  REMOTE_CMD="$*" expect -c "
    set timeout 60
    log_user 1
    spawn ssh $SSH_OPTS $GUEST_USER@$ip \$env(REMOTE_CMD)
    expect {
      -re {[Pp]assword:} { send \"$GUEST_PASS\r\"; exp_continue }
      eof
    }
    catch wait result
    exit [lindex \$result 3]
  "
}
guest_scp(){
  have_expect
  local src="$1" dst="$2"
  expect -c "
    set timeout 120
    log_user 0
    spawn scp $SSH_OPTS \"$src\" \"$dst\"
    expect {
      -re {[Pp]assword:} { send \"$GUEST_PASS\r\"; exp_continue }
      eof
    }
    catch wait result
    exit [lindex \$result 3]
  "
}

case "${1:-}" in
  pull)
    have_tart
    echo "[tart] pulling base image $BASE_IMAGE (large, ~30GB — one time) ..." >&2
    tart pull "$BASE_IMAGE"
    ;;
  clone)
    have_tart
    tart list --format json 2>/dev/null | grep -q "\"$VM\"" && die "VM '$VM' already exists (use 'down' first to recreate)"
    echo "[tart] cloning $BASE_IMAGE -> $VM ..." >&2
    tart clone "$BASE_IMAGE" "$VM"
    echo "[tart] created $VM" >&2
    ;;
  up)
    have_tart
    echo "[tart] starting $VM headless ..." >&2
    nohup tart run "$VM" --no-graphics >/tmp/tart-$VM.log 2>&1 &
    echo "[tart] started (log: /tmp/tart-$VM.log). Guest IP: $(sleep 5; guest_ip || echo 'pending')" >&2
    ;;
  view)
    have_tart
    echo "[tart] starting $VM with its own VNC window (host display untouched) ..." >&2
    nohup tart run "$VM" --vnc >/tmp/tart-$VM.log 2>&1 &
    echo "[tart] started; the VNC viewer opens in its own window. Log: /tmp/tart-$VM.log" >&2
    ;;
  ip)
    have_tart; guest_ip || die "VM not running";;
  ssh)
    have_tart
    ip="$(guest_ip)" || die "VM not running (start with 'up')"
    shift
    guest_ssh "$ip" "$@"
    ;;
  run)
    have_tart
    recipe="${2:-}"; [ -n "$recipe" ] || die "usage: tart.sh run <recipe-path>"
    [ -f "$recipe" ] || die "recipe not found: $recipe"
    ip="$(guest_ip)" || die "VM not running (start with 'up')"
    echo "[tart] shipping recipe to guest and running in-VM ..." >&2
    guest_scp "$recipe" "$GUEST_USER@$ip:/tmp/recipe.json"
    # The guest is expected to have its own runner; this is the seam for it.
    guest_ssh "$ip" 'echo "[guest] recipe staged at /tmp/recipe.json — run your in-guest computer-use here"'
    ;;
  setup-agent)
    have_tart
    ip="$(guest_ip)" || die "VM not running (start with 'up')"
    echo "[tart] installing self-operating-computer in guest venv (~/soc-venv) ..." >&2
    guest_ssh "$ip" 'python3 -m venv ~/soc-venv && ~/soc-venv/bin/pip install --upgrade pip self-operating-computer >/dev/null && echo "[guest] self-operating-computer ready at ~/soc-venv/bin/operate"'
    cat >&2 <<'EOF'
[tart] ONE-TIME manual step in the guest (macOS TCC cannot be granted over SSH):
  1. Open the guest screen:   vm/tart.sh view
  2. Guest System Settings > Privacy & Security, enable for "Terminal"
     (and ~/soc-venv/.../python): Screen Recording AND Accessibility.
  3. In a guest GUI Terminal, run `~/soc-venv/bin/operate` once to confirm it can
     see the screen and move the cursor. After that, `tart.sh agent` works.
EOF
    ;;
  agent)
    have_tart
    shift
    goal="$*"; [ -n "$goal" ] || die "usage: tart.sh agent \"<goal>\""
    ip="$(guest_ip)" || die "VM not running (start with 'up')"
    # LLM key comes from the CALLER's env, injected into the guest command only at
    # runtime (never written to the repo, never persisted on the guest disk).
    # self-operating-computer uses vendor keys directly (no custom base_url).
    key_env=""
    [ -n "${OPENAI_API_KEY:-}" ]    && key_env="$key_env OPENAI_API_KEY=$(shq "$OPENAI_API_KEY")"
    [ -n "${ANTHROPIC_API_KEY:-}" ] && key_env="$key_env ANTHROPIC_API_KEY=$(shq "$ANTHROPIC_API_KEY")"
    [ -n "${GOOGLE_API_KEY:-}" ]    && key_env="$key_env GOOGLE_API_KEY=$(shq "$GOOGLE_API_KEY")"
    [ -n "$key_env" ] || die "agent: no LLM key in env (export OPENAI_API_KEY / ANTHROPIC_API_KEY / GOOGLE_API_KEY)"
    if   [ -n "${SANDBOX_TART_AGENT_MODEL:-}" ]; then model="$SANDBOX_TART_AGENT_MODEL"
    elif [ -n "${OPENAI_API_KEY:-}" ];          then model="gpt-4-with-ocr"
    elif [ -n "${ANTHROPIC_API_KEY:-}" ];       then model="claude-3"
    else                                             model="gemini-pro-vision"; fi
    echo "[tart] agent (-m $model) driving guest GUI ..." >&2
    # pyautogui/screencapture need the guest's ACTIVE Aqua GUI session, not a bare
    # SSH context, so run inside it via `launchctl asuser <uid>`. Requires the
    # one-time Screen Recording + Accessibility grant from `setup-agent`.
    guest_ssh "$ip" "uid=\$(id -u $GUEST_USER); launchctl asuser \$uid env$key_env ~/soc-venv/bin/operate -m $model --prompt $(shq "$goal")"
    ;;
  stop)
    have_tart; tart stop "$VM" 2>/dev/null || true; echo "[tart] stopped $VM" >&2;;
  down)
    have_tart
    tart stop "$VM" 2>/dev/null || true
    tart delete "$VM" 2>/dev/null || true
    echo "[tart] deleted $VM (base image retained)" >&2
    ;;
  status)
    have_tart
    echo "base image: $BASE_IMAGE"
    echo "vm:         $VM"
    tart list 2>/dev/null || true
    ;;
  *)
    grep -E '^#( |$)' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1;;
esac
