#!/usr/bin/env bash
# vpn-auth-sso.sh
# Obtains an OpenConnect session cookie via SAML/SSO in a browser window
# and optionally pushes it to an OpenWrt router, restarting the oc-vpn
# service.
#
# Authentication: openconnect-sso (https://github.com/vlaci/openconnect-sso).
# Targets ASAs using the *embedded browser* SAML flow (single-sign-on-v2),
# which plain `openconnect --external-browser` cannot handle ("No SSO
# handler"): the server insists on an AnyConnect-style login window.
# openconnect-sso opens that window (Qt WebEngine), completes the SAML
# dance and prints HOST/COOKIE/FINGERPRINT (--authenticate shell).
# Some ASAs additionally demand a hostscan report even for the SAML group
# (error id=13 otherwise), which stock openconnect-sso does not support:
# openconnect-sso-csd.py (same dir) monkeypatches it to run csd-post.sh
# between the init request and the browser step.
#
# The session cookie is bound to the User-Agent that obtained it.
# openconnect-sso authenticates as "AnyConnect Linux_64 $AC_VERSION", so a
# matching VPN_USERAGENT line is appended to the session file; the router's
# oc-vpn init script sources the session file after its own config, picking
# up the override automatically.
#
# Usage:
#   ./vpn-auth-sso.sh              # authenticate, save cookie to ./session
#   ./vpn-auth-sso.sh -p           # + push to the router and restart oc-vpn
#   ./vpn-auth-sso.sh -c my.conf   # use an alternative config file
#   ./vpn-auth-sso.sh -s vpn.host -g GROUP -p
#
# Settings live in vpn.conf next to this script (shared with vpn-auth.sh
# and deploy.sh, see vpn.conf.example); the SAML tunnel-group comes from
# VPN_SSO_GROUP. -c FILE selects another config. Command-line flags
# override config values.
#
# Requires: openconnect-sso (uv tool install --python 3.12 \
#   --with "setuptools<81" openconnect-sso), ssh to the router.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared helpers: err/info, resolve_csd_wrapper, save_session,
# show_saved_session, push_session, manual_push_hint.
. "$SCRIPT_DIR/lib.sh"

# ================= DEFAULTS (overridden by config and flags) =================

VPN_SERVER="vpn.example.com"       # VPN server address
VPN_SSO_GROUP=""                   # tunnel-group (SAML/SSO one)

# AnyConnect version openconnect-sso impersonates; determines the User-Agent
# ("AnyConnect Linux_64 <version>") the cookie gets bound to.
AC_VERSION="4.7.00136"

# Extra openconnect-sso options (e.g. "--browser-display-mode shown -l DEBUG").
SSO_OPTS=""

# csd-wrapper (hostscan). The ASA demands a hostscan report even for the
# SAML group (error id=13 otherwise); openconnect-sso-csd.py runs this
# wrapper between the init request and the browser step. Empty =
# auto-detect among common paths (macOS/Linux), otherwise set an explicit
# path. If not found anywhere, it is downloaded next to this script.
CSD_WRAPPER=""
CSD_URL="https://gitlab.com/openconnect/openconnect/-/raw/master/trojans/csd-post.sh"

SESSION_FILE="$SCRIPT_DIR/session"             # where to save the cookie locally

OC_HOST="root@192.168.1.1"                   # router ssh address
OC_HOST_SESSION="/tmp/oc-vpn.session"        # session file path on the router (tmpfs)
PUSH=0                                         # 1 = push to the router right away (-p flag)

CONFIG="$SCRIPT_DIR/vpn.conf"            # default config path

# =============================================================================

usage() {
    sed -n '2,35p' "$0"
    exit 0
}

OPTSTRING="c:s:g:o:ph"

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
        g) VPN_SSO_GROUP="$OPTARG" ;;
        o) SSO_OPTS="$OPTARG" ;;
        p) PUSH=1 ;;
        *) ;;
    esac
done

command -v openconnect-sso >/dev/null || {
    err "openconnect-sso not found. Install:"
    err '  uv tool install --python 3.12 --with "setuptools<81" openconnect-sso'
    exit 1
}

# The CSD monkeypatch must run inside openconnect-sso's own virtualenv.
PYBIN="$(sed -n '1s/^#! *//p' "$(command -v openconnect-sso)")"
[ -x "$PYBIN" ] || { err "cannot resolve openconnect-sso's python: $PYBIN"; exit 1; }

resolve_csd_wrapper || { err "csd-wrapper unavailable. Install openconnect with trojans or set CSD_WRAPPER."; exit 1; }

# pin-sha256 of the server public key for csd-post.sh certificate pinning
# (openconnect exports the same as CSD_SHA256). Best effort: when empty,
# csd-post.sh falls back to regular CA validation.
CSD_SHA256="$(openssl s_client -connect "$VPN_SERVER:443" -servername "$VPN_SERVER" </dev/null 2>/dev/null \
    | openssl x509 -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform der 2>/dev/null \
    | openssl dgst -sha256 -binary 2>/dev/null | base64)"
[ -n "$CSD_SHA256" ] || err "warning: could not compute the server cert pin; hostscan will use CA validation"

# --- openconnect-sso arguments ---
ARGS=(
    --server "$VPN_SERVER"
    --authenticate shell
    --ac-version "$AC_VERSION"
)
[ -n "$VPN_SSO_GROUP" ] && ARGS+=(--authgroup "$VPN_SSO_GROUP")
# shellcheck disable=SC2206
ARGS+=($SSO_OPTS)

TMP="$(mktemp)" || exit 1
trap 'rm -f "$TMP"' EXIT

info "Authenticating to $VPN_SERVER (group $VPN_SSO_GROUP) via browser SSO..."
echo  "Command: openconnect-sso ${ARGS[*]}"
echo
info "A login window will open. Log in there by hand (no autofill; nothing"
info "is stored anywhere)."
echo

# Logs go to the terminal (stderr), HOST/COOKIE/FINGERPRINT to stdout ($TMP).
# openconnect-sso-csd.py = openconnect-sso + hostscan, no autofill/keyring
# (see its header).
CSD_WRAPPER="$CSD_WRAPPER" CSD_SHA256="$CSD_SHA256" \
    "$PYBIN" "$SCRIPT_DIR/openconnect-sso-csd.py" "${ARGS[@]}" > "$TMP"
rc=$?

if [ "$rc" != 0 ]; then
    err "Authentication failed (exit $rc)."
    cat "$TMP" >&2
    exit 1
fi

if ! grep -q '^COOKIE=' "$TMP"; then
    err "openconnect-sso finished, but no COOKIE was received. Output:"
    cat "$TMP" >&2
    exit 1
fi

# Keep only the session variables (drop any stray log lines) and record the
# User-Agent the cookie is bound to; the router's init script sources this
# file after its config, so VPN_USERAGENT here overrides the router default.
{
    grep -E '^(HOST|COOKIE|FINGERPRINT)=' "$TMP"
    printf "VPN_USERAGENT='AnyConnect Linux_64 %s'\n" "$AC_VERSION"
} | save_session
show_saved_session 'HOST|FINGERPRINT|VPN_USERAGENT'

if [ "$PUSH" = 1 ]; then
    push_session || exit 1
else
    echo
    echo "To push to the router and restart the VPN:"
    echo "  $0 ... -p"
    echo "or manually:"
    manual_push_hint
fi
