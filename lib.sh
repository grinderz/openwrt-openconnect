# shellcheck shell=bash
# shellcheck disable=SC2029  # $OC_HOST_SESSION in the ssh command expands client-side on purpose
# lib.sh -- shared helpers for vpn-auth.sh and vpn-auth-sso.sh.
# Sourced, not executed; defines functions only (no side effects).
# The caller must define: SCRIPT_DIR, SESSION_FILE, OC_HOST, OC_HOST_SESSION,
# CSD_WRAPPER, CSD_URL.

err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
info() { printf '\033[32m%s\033[0m\n' "$*"; }

# Locate csd-post.sh: explicit CSD_WRAPPER -> common macOS/Linux paths -> download.
resolve_csd_wrapper() {
    [ -n "$CSD_WRAPPER" ] && { [ -x "$CSD_WRAPPER" ] && return 0; err "CSD_WRAPPER is set but not executable: $CSD_WRAPPER"; return 1; }

    local c cands=()
    command -v brew >/dev/null && cands+=("$(brew --prefix openconnect 2>/dev/null)/libexec/openconnect/csd-post.sh")
    cands+=(
        /opt/homebrew/opt/openconnect/libexec/openconnect/csd-post.sh  # macOS ARM brew
        /usr/local/opt/openconnect/libexec/openconnect/csd-post.sh     # macOS Intel brew
        /usr/lib/openconnect/csd-post.sh                               # Debian/Ubuntu
        /usr/libexec/openconnect/csd-post.sh                           # Fedora/RHEL
        /usr/share/openconnect/csd-post.sh
        "$SCRIPT_DIR/csd-post.sh"                                      # downloaded earlier
    )
    for c in "${cands[@]}"; do
        [ -f "$c" ] || continue
        [ -x "$c" ] || chmod +x "$c" 2>/dev/null || true
        CSD_WRAPPER="$c"; return 0
    done

    # Not found anywhere -- download next to this script.
    CSD_WRAPPER="$SCRIPT_DIR/csd-post.sh"
    info "csd-post.sh not found on the system, downloading -> $CSD_WRAPPER"
    if command -v curl >/dev/null; then
        curl -fsSL -o "$CSD_WRAPPER" "$CSD_URL" || return 1
    elif command -v wget >/dev/null; then
        wget -qO "$CSD_WRAPPER" "$CSD_URL" || return 1
    else
        err "No curl/wget available to download csd-post.sh."; return 1
    fi
    chmod +x "$CSD_WRAPPER"
}

# Write stdin to $SESSION_FILE with guaranteed 600 permissions: the umask
# only applies to newly created files, so an old session file with looser
# permissions is removed first (the cookie is a secret).
save_session() {
    mkdir -p "$(dirname "$SESSION_FILE")"
    rm -f "$SESSION_FILE"
    ( umask 077; cat > "$SESSION_FILE" )
}

# Print the saved session with the cookie hidden; $1 = regex of the
# non-secret fields to show (e.g. 'HOST|FINGERPRINT').
show_saved_session() {
    info "Cookie obtained and saved to $SESSION_FILE"
    echo "-----------------------------------------"
    grep -E "^($1)=" "$SESSION_FILE"
    echo "COOKIE=<hidden, $(grep '^COOKIE=' "$SESSION_FILE" | wc -c | tr -d ' ') bytes>"
    echo "-----------------------------------------"
}

manual_push_hint() {
    echo "  ssh $OC_HOST 'umask 077; cat > $OC_HOST_SESSION && /etc/init.d/oc-vpn restart' < $SESSION_FILE"
}

# Push $SESSION_FILE to the router, restart oc-vpn and wait for the tunnel.
push_session() {
    info "Pushing the session to router $OC_HOST..."
    # Write via ssh with umask 077 so the file is 600 from the start
    # (scp would briefly leave it world-readable in /tmp).
    if ssh "$OC_HOST" "umask 077; cat > $OC_HOST_SESSION && /etc/init.d/oc-vpn restart" < "$SESSION_FILE"; then
        info "Done: oc-vpn service on the router restarted."
        info "Waiting for the tunnel to come up..."
        # Poll for the tunnel address (tun state stays UNKNOWN, so grep
        # for the assigned IP, not for UP)
        ssh "$OC_HOST" sh <<'REMOTE'
. /etc/openconnect-vpn/config 2>/dev/null
IFACE="${VPN_IFACE:-vpntun}"
i=0
while [ "$i" -lt 20 ]; do
    ip -brief addr show "$IFACE" 2>/dev/null | grep -q / && break
    sleep 1
    i=$((i + 1))
done
if ip -brief addr show "$IFACE" 2>/dev/null | grep -q /; then
    ip -brief addr show "$IFACE"
else
    echo "tunnel is not up after 20s; recent log:"
    logread | grep -E 'openconnect|oc-vpn' | tail -n 10
fi
REMOTE
    else
        err "Failed to push to the router. Copy manually:"
        manual_push_hint
        return 1
    fi
}
