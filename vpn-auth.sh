#!/usr/bin/env bash
# vpn-auth.sh
# Obtains an OpenConnect session cookie (Cisco ASA, tunnel-group with
# login + password + SMS code) and optionally pushes it to an OpenWrt
# router, restarting the oc-vpn service.
#
# Authentication: plain openconnect --authenticate, form-based
# (--no-external-auth, no SAML/browser). The password comes from `pass`,
# the second factor (SMS code) is prompted for in the terminal.
# Hostscan (CSD) is handled by the stock csd-post.sh from the
# openconnect brew package.
#
# Usage:
#   ./vpn-auth.sh                  # authenticate, save cookie to ./session
#   ./vpn-auth.sh -p               # + push to the router and restart oc-vpn
#   ./vpn-auth.sh -c my.conf       # use an alternative config file
#   ./vpn-auth.sh -s vpn.host -g GROUP -u user -p
#
# Settings live in vpn.conf next to this script (shared with
# vpn-auth-sso.sh and deploy.sh, see vpn.conf.example); -c FILE selects
# another config. Command-line flags override config values.
#
# Requires: openconnect 9.x+, pass (or your own PASSWORD_CMD), ssh to the router.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared helpers: err/info, resolve_csd_wrapper, save_session,
# show_saved_session, push_session, manual_push_hint.
. "$SCRIPT_DIR/lib.sh"

# ================= DEFAULTS (overridden by config and flags) =================

VPN_SERVER="vpn.example.com"       # VPN server address
VPN_PROTOCOL="anyconnect"          # anyconnect | gp | pulse | f5 | fortinet
VPN_USER="user"                    # login
VPN_GROUP=""                       # tunnel-group (form auth: password + SMS)

# Command that prints the password to stdout (first factor).
PASSWORD_CMD="pass vpn/password"

# Other openconnect options.
EXTRA_OPTS="--disable-ipv6 --useragent=AnyConnect"

# csd-wrapper (hostscan). Empty = auto-detect among common paths (macOS/Linux),
# otherwise set an explicit path. If not found anywhere, it is downloaded
# next to this script.
CSD_WRAPPER=""
CSD_URL="https://gitlab.com/openconnect/openconnect/-/raw/master/trojans/csd-post.sh"

SESSION_FILE="$SCRIPT_DIR/session"             # where to save the cookie locally

OC_HOST="root@192.168.1.1"                   # router ssh address
OC_HOST_SESSION="/tmp/oc-vpn.session"        # session file path on the router (tmpfs)
PUSH=0                                         # 1 = push to the router right away (-p flag)

CONFIG="$SCRIPT_DIR/vpn.conf"            # default config path

# =============================================================================

usage() {
    sed -n '2,24p' "$0"
    exit 0
}

OPTSTRING="c:s:P:u:g:o:ph"

# Pass 1: only -c, so the config is sourced before other flags apply.
while getopts "$OPTSTRING" opt; do
    case "$opt" in
        c) CONFIG="$OPTARG"
           [ -f "$CONFIG" ] || { err "config not found: $CONFIG"; exit 1; } ;;
        h) usage ;;
        \?) usage ;;
        *) ;;
    esac
done

# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"

# Pass 2: the rest of the flags override config values.
OPTIND=1
while getopts "$OPTSTRING" opt; do
    case "$opt" in
        s) VPN_SERVER="$OPTARG" ;;
        P) VPN_PROTOCOL="$OPTARG" ;;
        u) VPN_USER="$OPTARG" ;;
        g) VPN_GROUP="$OPTARG" ;;
        o) EXTRA_OPTS="$OPTARG" ;;
        p) PUSH=1 ;;
        *) ;;
    esac
done

command -v openconnect >/dev/null || {
    err "openconnect not found. macOS: brew install openconnect; Debian/Ubuntu: apt install openconnect"
    exit 1
}

resolve_csd_wrapper || { err "csd-wrapper unavailable. Install openconnect with trojans or set CSD_WRAPPER."; exit 1; }

# --- first factor: password from PASSWORD_CMD ---
if ! VPN_PASSWORD="$(eval "$PASSWORD_CMD")" || [ -z "$VPN_PASSWORD" ]; then
    err "Failed to obtain the password via: $PASSWORD_CMD"
    exit 1
fi

# Do NOT ask for the SMS code upfront: the server only sends it AFTER the
# password is submitted. The password goes first, then we wait for the SMS
# and enter the code (see run_auth).

# --- openconnect arguments ---
# shellcheck disable=SC2206
ARGS=(
    --authenticate
    --protocol="$VPN_PROTOCOL"
    --user="$VPN_USER"
    --no-external-auth
    --passwd-on-stdin
    --csd-user="${USER:-$(id -un)}"
    --csd-wrapper="$CSD_WRAPPER"
)
[ -n "$VPN_GROUP" ] && ARGS+=(--authgroup="$VPN_GROUP")
# shellcheck disable=SC2206
ARGS+=($EXTRA_OPTS "$VPN_SERVER")

# Ask the user for the SMS code (terminal or GUI dialog on macOS).
read_2fa() {
    local code=""
    if [ -r /dev/tty ]; then
        printf 'Got the SMS code? Enter it: ' > /dev/tty
        read -r code < /dev/tty
    elif [ "$(uname -s)" = "Darwin" ]; then
        code="$(osascript -e 'text returned of (display dialog "SMS code:" default answer "" with title "vpn-auth")')"
    fi
    printf '%s' "$code"
}

run_auth() {
    # Keep openconnect's stdin open via a FIFO: send the password first
    # (first factor) -> the server sends an SMS -> prompt for the code ->
    # append it to the same stream.
    # openconnect prompts/progress go to the terminal (stderr),
    # COOKIE/HOST/FINGERPRINT go to stdout ($TMP).
    local fifo rc
    fifo="$(mktemp -u)" || return 1
    mkfifo "$fifo" || return 1

    openconnect "${ARGS[@]}" > "$TMP" < "$fifo" &
    local oc_pid=$!

    # Open the FIFO for writing (fd 3). The password goes out immediately.
    exec 3>"$fifo"
    printf '%s\n' "$VPN_PASSWORD" >&3

    info "Password sent. Waiting for SMS..."
    # Wrong password: openconnect exits before the SMS stage. Catch it
    # here instead of sitting at a prompt for a code nobody will check.
    sleep 2
    if ! kill -0 "$oc_pid" 2>/dev/null; then
        err "openconnect exited before the SMS stage (wrong password?)."
        exec 3>&-; rm -f "$fifo"
        wait "$oc_pid" 2>/dev/null
        return 1
    fi

    local code; code="$(read_2fa)"
    if [ -z "$code" ]; then
        err "No SMS code entered."
        exec 3>&-; kill "$oc_pid" 2>/dev/null; rm -f "$fifo"
        return 1
    fi
    # Writing the code into the FIFO after openconnect died would kill
    # this script with SIGPIPE -- check again before the write.
    if ! kill -0 "$oc_pid" 2>/dev/null; then
        err "openconnect exited while waiting for the SMS code."
        exec 3>&-; rm -f "$fifo"
        wait "$oc_pid" 2>/dev/null
        return 1
    fi
    printf '%s\n' "$code" >&3

    exec 3>&-            # close stdin -> openconnect won't hang on extra prompts
    wait "$oc_pid"; rc=$?
    rm -f "$fifo"
    return $rc
}

TMP="$(mktemp)" || exit 1
trap 'rm -f "$TMP"' EXIT

info "Authenticating to $VPN_SERVER (group $VPN_GROUP, protocol $VPN_PROTOCOL)..."
echo  "Command: openconnect ${ARGS[*]}"
echo

if ! run_auth; then
    err "Authentication failed."
    cat "$TMP" >&2
    exit 1
fi

if ! grep -q '^COOKIE=' "$TMP"; then
    err "openconnect finished, but no COOKIE was received. Output:"
    cat "$TMP" >&2
    exit 1
fi

save_session < "$TMP"
show_saved_session 'HOST|FINGERPRINT'

if [ "$PUSH" = 1 ]; then
    push_session || exit 1
else
    echo
    echo "To push to the router and restart the VPN:"
    echo "  $0 ... -p"
    echo "or manually:"
    manual_push_hint
fi
