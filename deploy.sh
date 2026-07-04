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
#   ROUTER=root@10.0.0.1 ./deploy.sh
#
# The router address comes from ROUTER in vpn-auth.conf (or the file
# given with -c). The ROUTER environment variable overrides the config.

set -eu

BASE="$(cd "$(dirname "$0")" && pwd)"
SRC="$BASE/etc"
CONFIG="$BASE/vpn-auth.conf"

ROUTER_ENV="${ROUTER:-}"

DRY_RUN=0
while getopts "c:nh" opt; do
    case "$opt" in
        c) CONFIG="$OPTARG"
           [ -f "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 1; } ;;
        n) DRY_RUN=1 ;;
        h|*) sed -n '2,15p' "$0"; exit 0 ;;
    esac
done

ROUTER="root@192.168.1.1"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
[ -n "$ROUTER_ENV" ] && ROUTER="$ROUTER_ENV"

# File list: local_path  remote_path  mode
FILES="
openconnect-vpn/config       /etc/openconnect-vpn/config   600
openconnect-vpn/vpnc-script  /etc/openconnect-vpn/vpnc-script  755
init.d/oc-vpn.init           /etc/init.d/oc-vpn            755
"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# One ssh connection for everything: ControlMaster.
# SSHN (-n, no stdin) for remote commands: inside the while-read loop
# plain ssh would swallow the loop's stdin (the file list).
# SSH (with stdin) only for uploads.
CTL="$HOME/.ssh/deploy-%r@%h:%p"
SSH="ssh -o ControlMaster=auto -o ControlPath=$CTL -o ControlPersist=30"
SSHN="$SSH -n"

remote_sha() {
    # sha256 of the file on the router, empty if the file is missing
    $SSHN "$ROUTER" "sha256sum '$1' 2>/dev/null" | cut -d' ' -f1
}

local_sha() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

CHANGED=0

while read -r local remote mode; do
    [ -n "$local" ] || continue
    src="$SRC/$local"
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

    # The config may contain manual edits made on the router: never
    # overwrite it -- upload the new version next to it as config.new
    # and let the user merge by hand. Installed directly only if absent.
    if [ "$remote" = "/etc/openconnect-vpn/config" ] && \
       $SSHN "$ROUTER" "[ -f '$remote' ]"; then
        info "$remote exists, uploading as $remote.new (merge manually)"
        $SSH "$ROUTER" "cat > '$remote.new' && chmod $mode '$remote.new'" < "$src"
        continue
    fi

    info "updating $remote"
    # Upload via ssh pipe: scp needs sftp-server on the router,
    # which dropbear does not ship
    $SSH "$ROUTER" "mkdir -p '$(dirname "$remote")' && cat > '$remote' && chmod $mode '$remote'" < "$src"
    CHANGED=1
done <<EOF
$FILES
EOF

if [ "$DRY_RUN" = 1 ]; then
    info "dry run: nothing was changed"
elif [ "$CHANGED" = 1 ]; then
    info "done; apply with: ssh $ROUTER '/etc/init.d/oc-vpn restart'"
else
    info "everything up to date"
fi

# Close the master connection
$SSH -O exit "$ROUTER" 2>/dev/null || true
