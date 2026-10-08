#!/bin/sh
# deploy.sh -- install/update files from etc/ onto an OpenWrt router over ssh.
#
# Copies only changed files (sha256 comparison) and sets permissions.
# Does NOT enable or restart the oc-vpn service -- do that manually:
#   ssh <router> '/etc/init.d/oc-vpn restart'
#
# Usage:
#   ./deploy.sh              # deploy changed files
#   ./deploy.sh -n           # dry run: show what would change
#   ./deploy.sh -c my.conf   # use an alternative config file
#   OC_HOST=root@10.0.0.1 ./deploy.sh
#
# The router address comes from OC_HOST in vpn.conf (or the file
# given with -c). The OC_HOST environment variable overrides the config.
# RC_<KEY> values in vpn.conf are patched into etc/openconnect-vpn/config
# before upload and make that file managed from here (see below).
# (Deliberately not plain HOST: zsh and some systems set that to the
# local hostname.)

set -eu

BASE="$(cd "$(dirname "$0")" && pwd)"
SRC="$BASE/etc"
CONFIG="$BASE/vpn.conf"
[ -f "$CONFIG" ] || CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/openwrt-openconnect/vpn.conf"

OC_HOST_ENV="${OC_HOST:-}"

DRY_RUN=0
while getopts "c:nh" opt; do
    case "$opt" in
        c) CONFIG="$OPTARG"
           [ -f "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 1; } ;;
        n) DRY_RUN=1 ;;
        h|*) sed -n '2,17p' "$0"; exit 0 ;;
    esac
done

OC_HOST="root@192.168.1.1"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
[ -n "$OC_HOST_ENV" ] && OC_HOST="$OC_HOST_ENV"

# File list: local_path  remote_path  mode
FILES="
openconnect-vpn/config       /etc/openconnect-vpn/config   600
openconnect-vpn/vpnc-script  /etc/openconnect-vpn/vpnc-script  755
openconnect-vpn/run.sh       /etc/openconnect-vpn/run.sh       755
init.d/oc-vpn.init           /etc/init.d/oc-vpn            755
"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# /etc/openconnect-vpn/config: the repo file is a template. RC_<KEY> values
# from vpn.conf (dotfiles renders them from [data.openwrt_openconnect.router_config])
# replace the matching KEY= lines. With at least one RC_ set the config is
# managed from here: the router's copy is replaced, the previous one kept as
# config.bak. Without any, the old behaviour: the router's copy is left alone
# and the template goes up as config.new to merge by hand.
RC_KEYS="VPN_PROTOCOL VPN_USERAGENT DISABLE_IPV6 DISABLE_DTLS VPN_IFACE SESSION_FILE VPN_ROUTES IGNORE_SERVER_ROUTES USE_DEFAULT_ROUTE USE_VPN_DNS VPN_DNS_DOMAINS LOG_SERVER_CONFIG"
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED" "$RENDERED.tmp"' EXIT
CONFIG_MANAGED=0
cp "$SRC/openconnect-vpn/config" "$RENDERED"
for k in $RC_KEYS; do
    is_set=''; v=''
    eval "is_set=\${RC_$k+set}; v=\${RC_$k:-}"
    [ -n "$is_set" ] || continue
    CONFIG_MANAGED=1
    K="$k" V="$v" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
        index($0, k "=") == 1 { print k "=\"" v "\""; next } { print }' \
        "$RENDERED" > "$RENDERED.tmp" && mv "$RENDERED.tmp" "$RENDERED"
done

# One ssh connection for everything: ControlMaster.
# SSHN (-n, no stdin) for remote commands: inside the while-read loop
# plain ssh would swallow the loop's stdin (the file list).
# SSH (with stdin) only for uploads.
CTL="$HOME/.ssh/deploy-%r@%h:%p"
SSH="ssh -o ControlMaster=auto -o ControlPath=$CTL -o ControlPersist=30"
SSHN="$SSH -n"

# Fail early with a clear error if the router is unreachable; this also
# opens the ControlMaster connection reused by every later call.
$SSHN "$OC_HOST" true || { echo "cannot reach $OC_HOST" >&2; exit 1; }

# All remote hashes in one round trip instead of one ssh call per file.
# sha256sum exits non-zero when some files are missing but still prints
# the hashes of the ones it found -- that is all we need.
# Single line: a newline-separated list would be run by the remote shell
# as separate commands (i.e. would EXECUTE the deployed scripts).
REMOTE_PATHS="$(echo "$FILES" | awk 'NF { printf "%s ", $2 }')"
REMOTE_SUMS="$($SSHN "$OC_HOST" "sha256sum $REMOTE_PATHS 2>/dev/null" || true)"

remote_sha() {
    # sha256 of the file on the router, empty if the file is missing
    echo "$REMOTE_SUMS" | awk -v f="$1" '$2 == f { print $1 }'
}

local_sha() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

CHANGED=0
NEEDS_MERGE=0

while read -r local remote mode; do
    [ -n "$local" ] || continue
    src="$SRC/$local"
    [ "$remote" = "/etc/openconnect-vpn/config" ] && src="$RENDERED"
    [ -f "$src" ] || { echo "missing file: $src" >&2; exit 1; }

    if [ "$(local_sha "$src")" = "$(remote_sha "$remote")" ]; then
        printf '    %-35s unchanged\n' "$remote"
        continue
    fi

    if [ "$DRY_RUN" = 1 ]; then
        printf '    %-35s \033[1;33mwould be updated\033[0m\n' "$remote"
        CHANGED=1
        continue
    fi

    # An unmanaged config may contain manual edits made on the router: never
    # overwrite it -- upload the new version next to it as config.new
    # and let the user merge by hand. Installed directly only if absent.
    if [ "$remote" = "/etc/openconnect-vpn/config" ] && [ "$CONFIG_MANAGED" = 0 ] && \
       $SSHN "$OC_HOST" "[ -f '$remote' ]"; then
        info "$remote exists, uploading as $remote.new (merge manually)"
        $SSH "$OC_HOST" "cat > '$remote.new' && chmod $mode '$remote.new'" < "$src"
        CHANGED=1
        NEEDS_MERGE=1
        continue
    fi

    # A managed config replaces the router's copy; keep one generation back
    if [ "$remote" = "/etc/openconnect-vpn/config" ]; then
        $SSHN "$OC_HOST" "[ ! -f '$remote' ] || cp '$remote' '$remote.bak'"
    fi

    info "updating $remote"
    # Upload via ssh pipe: scp needs sftp-server on the router,
    # which dropbear does not ship
    $SSH "$OC_HOST" "mkdir -p '$(dirname "$remote")' && cat > '$remote' && chmod $mode '$remote'" < "$src"
    CHANGED=1
done <<EOF
$FILES
EOF

# Keep the VPN config across sysupgrade: list it in /etc/sysupgrade.conf
KEEP="/etc/openconnect-vpn/config"
if ! $SSHN "$OC_HOST" "grep -qxF '$KEEP' /etc/sysupgrade.conf 2>/dev/null"; then
    if [ "$DRY_RUN" = 1 ]; then
        printf '    %-35s \033[1;33mwould be added to /etc/sysupgrade.conf\033[0m\n' "$KEEP"
        CHANGED=1
    else
        info "adding $KEEP to /etc/sysupgrade.conf"
        $SSHN "$OC_HOST" "echo '$KEEP' >> /etc/sysupgrade.conf"
        CHANGED=1
    fi
else
    printf '    %-35s in sysupgrade.conf\n' "$KEEP"
fi

if [ "$DRY_RUN" = 1 ]; then
    info "dry run: nothing was changed"
elif [ "$CHANGED" = 1 ]; then
    info "done; apply with: ssh $OC_HOST '/etc/init.d/oc-vpn restart'"
    if [ "$NEEDS_MERGE" = 1 ]; then
        info "config uploaded as config.new: merge it into /etc/openconnect-vpn/config on the router"
    fi
else
    info "everything up to date"
fi

# Close the master connection
$SSH -O exit "$OC_HOST" 2>/dev/null || true
