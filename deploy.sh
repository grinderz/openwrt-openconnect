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
# (Deliberately not plain HOST: zsh and some systems set that to the
# local hostname.)

set -eu

BASE="$(cd "$(dirname "$0")" && pwd)"
SRC="$BASE/etc"
CONFIG="$BASE/vpn.conf"

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
       $SSHN "$OC_HOST" "[ -f '$remote' ]"; then
        info "$remote exists, uploading as $remote.new (merge manually)"
        $SSH "$OC_HOST" "cat > '$remote.new' && chmod $mode '$remote.new'" < "$src"
        CHANGED=1
        NEEDS_MERGE=1
        continue
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
