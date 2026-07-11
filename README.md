# vpn-auth

Obtains an OpenConnect session cookie (Cisco ASA) on a desktop machine and
optionally pushes it to an OpenWrt router, restarting the `oc-vpn` service.
Two authentication paths, one per tunnel-group type:

- `vpn-auth.sh` — form-based login + password + SMS code
- `vpn-auth-sso.sh` — SAML/SSO in a browser window

Shared helper functions (csd-wrapper lookup, session save/push) live in
`lib.sh`, sourced by both scripts.

## Authentication

### Password + SMS (`vpn-auth.sh`)

Plain `openconnect --authenticate`, form-based (`--no-external-auth`, no SAML/browser):

- **1st factor** — password from `pass` (the `PASSWORD_CMD` variable).
- **2nd factor** — SMS code. The password goes first through an open FIFO → the server
  sends an SMS → the script prompts for the code → appends it to the same stream.
- **Hostscan (CSD)** — the stock `csd-post.sh` from the openconnect brew package.

### Browser SAML/SSO (`vpn-auth-sso.sh`)

For tunnel-groups using the *embedded browser* SAML flow (single-sign-on-v2),
which plain `openconnect --external-browser` cannot handle ("No SSO handler").
Uses [openconnect-sso](https://github.com/vlaci/openconnect-sso) (Qt WebEngine
login window; the form is filled by hand — no autofill, no keyring). Install:

```sh
uv tool install --python 3.12 --with "setuptools<81" openconnect-sso
```

Some ASAs demand a hostscan report even for the SAML group (`error id=13`
otherwise), which stock openconnect-sso does not support:
`openconnect-sso-csd.py` monkeypatches it to run `csd-post.sh` between the
init request and the browser step.

The cookie is bound to the User-Agent that obtained it; the script records a
matching `VPN_USERAGENT` in the session file and the router picks it up
automatically.

## Configuration

Settings (server, login, tunnel-groups, `PASSWORD_CMD`, router address) live
in a single `vpn.conf` next to the scripts, shared by `vpn-auth.sh`,
`vpn-auth-sso.sh` and `deploy.sh` — copy `vpn.conf.example` and edit. The
two authentication paths use separate tunnel-group variables: `VPN_GROUP`
(form auth) and `VPN_SSO_GROUP` (SAML). An alternative file can be passed
with `-c FILE`. Command-line flags override config values, and the `OC_HOST`
environment variable overrides the router address from the config.

Usage:

```sh
./vpn-auth.sh          # cookie saved locally to ./session
./vpn-auth.sh -p       # + push to the router and restart oc-vpn
./vpn-auth.sh -c work.conf -p
./vpn-auth-sso.sh -p   # same via browser SSO
./deploy.sh            # push etc/ files to the router (deploy/update)
./deploy.sh -n         # dry run: show what would change
```

`deploy.sh` only copies files (and keeps `/etc/openconnect-vpn/config` listed
in `/etc/sysupgrade.conf` so it survives firmware upgrades) — after it, apply
changes with:

```sh
ssh root@192.168.1.1 '/etc/init.d/oc-vpn restart'
```

If `/etc/openconnect-vpn/config` already exists on the router, `deploy.sh`
uploads the new version as `config.new` instead of overwriting — merge
manual edits by hand.

## Router setup (OpenWrt)

One-time preparation on the router, in addition to `./deploy.sh`:

1. Install openconnect: `opkg update && opkg install openconnect`
   (pulls in `kmod-tun`).
2. Declare the tunnel interface in `/etc/config/network` — the name must
   match `VPN_IFACE` in `/etc/openconnect-vpn/config`:

   ```
   config interface 'vpn'
       option proto 'none'
       option device 'vpntun'
   ```

3. Add the interface to a firewall zone in `/etc/config/firewall` (e.g. a
   `vpn` zone with forwarding from `lan`), otherwise LAN traffic will not
   pass through the tunnel:

   ```
   config zone
       option name 'vpn'
       list network 'vpn'
       option input 'REJECT'
       option output 'ACCEPT'
       option forward 'REJECT'
       option masq '1'
       option mtu_fix '1'

   config forwarding
       option src 'lan'
       option dest 'vpn'
   ```

4. Reload: `service network reload && service firewall reload`.
5. Enable the service so it starts on boot: `service oc-vpn enable`.
   `deploy.sh` only copies files; enabling and restarting `oc-vpn` is manual.

Diagnostics on the router: `/etc/init.d/oc-vpn diag` — shows the interface
state, tunnel routes and recent log lines.

The session file lives in `/tmp/oc-vpn.session` (tmpfs): it does not survive
a reboot — push a fresh one with `./vpn-auth.sh -p`.

If the server rejects the cookie (expired session, HTTP 401) three times in
a row, the service stops itself instead of retrying forever — check
`logread` for `cookie rejected by server`, then push a fresh session with
`./vpn-auth.sh -p` (it restarts the service).

## Session timeouts (Cisco ASA)

Values reported by the server (CSTP CONNECT headers):

| Parameter                    | Value             | Meaning                                                            |
|------------------------------|-------------------|--------------------------------------------------------------------|
| `X-CSTP-Session-Timeout`     | 345600 s = **96 h (4 days)** | Hard maximum from the moment of auth. After that the cookie is dead — a new login with SMS is required. |
| `X-CSTP-Idle-Timeout`        | 18000 s = **5 h** | No traffic for 5 h straight → session is dropped.                  |
| `X-CSTP-Disconnected-Timeout`| 18000 s = **5 h** | Tunnel went down — the same cookie can re-establish it within 5 h. |
| DPD / Keepalive              | 30 / 20 s         | openconnect sends keepalives itself, so there is effectively no traffic idle. |

**Bottom line:** the cookie hard-expires **4 days** after it is obtained. Earlier only
if the tunnel sits with no traffic for 5 h or stays disconnected longer than 5 h. With
the tunnel up, keepalives keep it alive, so you hit the 96-hour limit.

The 96 h countdown starts at auth time (not at connect), and reconnecting with the same
cookie does not reset it. Run `vpn-auth.sh` roughly every 4 days; it cannot be
fully automated because of the interactive SMS factor.
