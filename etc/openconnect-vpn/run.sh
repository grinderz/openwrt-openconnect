#!/bin/sh
# /etc/openconnect-vpn/run.sh
# procd wrapper around openconnect. procd respawns the instance on ANY
# exit, which turns an expired cookie into an endless 401 loop against
# the server. openconnect exits with code 2 when the server rejects the
# cookie (see EXIT STATUS in openconnect(8)); count consecutive
# rejections and stop the service after REJECT_LIMIT of them. Any other
# exit (network drop, WAN not up yet at boot) resets the counter, so
# ordinary reconnects keep retrying forever as before.
#
# The counter lives in /tmp and is removed by start_service, so a
# restart after pushing a fresh session (vpn-auth.sh -p) starts clean.

RUNCFG="/tmp/oc-vpn.runtime.conf"
REJECT_COUNT="/tmp/oc-vpn.cookie-rejected"
REJECT_LIMIT=3

HOST="$1"

give_up() {
    logger -t oc-vpn -p daemon.err \
        "cookie rejected by server $REJECT_LIMIT times in a row: stopping oc-vpn; push a fresh session with vpn-auth.sh -p"
    # Exiting here would only make procd respawn us: the stop must come
    # from outside. The background job survives this shell; the sleep
    # keeps the instance alive until procd's TERM (sent by stop) lands,
    # otherwise procd respawns before the stop takes effect.
    /etc/init.d/oc-vpn stop &
    sleep 30
    exit 1
}

n="$(cat "$REJECT_COUNT" 2>/dev/null || echo 0)"
# Respawned after the limit was already reached (stop lost the race)
[ "$n" -ge "$REJECT_LIMIT" ] && give_up

/usr/sbin/openconnect --config "$RUNCFG" "$HOST"
rc=$?

if [ "$rc" = 2 ]; then
    n=$((n + 1))
    echo "$n" > "$REJECT_COUNT"
    logger -t oc-vpn -p daemon.warn "cookie rejected by server ($n/$REJECT_LIMIT)"
    [ "$n" -ge "$REJECT_LIMIT" ] && give_up
else
    rm -f "$REJECT_COUNT"
fi
exit $rc
