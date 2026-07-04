# vpn-auth

Obtains an OpenConnect session cookie (Cisco ASA, tunnel-group with
login + password + SMS authentication) and optionally pushes it to an
OpenWrt router, restarting the `oc-vpn` service.

## Authentication

Plain `openconnect --authenticate`, form-based (`--no-external-auth`, no SAML/browser):

- **1st factor** — password from `pass` (the `PASSWORD_CMD` variable).
- **2nd factor** — SMS code. The password goes first through an open FIFO → the server
  sends an SMS → the script prompts for the code → appends it to the same stream.
- **Hostscan (CSD)** — the stock `csd-post.sh` from the openconnect brew package.

## Configuration

Settings (server, login, tunnel-group, `PASSWORD_CMD`, router address) live in
`vpn-auth.conf` next to the scripts — copy `vpn-auth.conf.example`
and edit. Both `vpn-auth.sh` and `deploy.sh` read it; an alternative file
can be passed with `-c FILE`. Command-line flags override config values.

Usage:

```sh
./vpn-auth.sh          # cookie saved locally to ./session
./vpn-auth.sh -p       # + push to the router and restart oc-vpn
./vpn-auth.sh -c work.conf -p
./deploy.sh            # push etc/ files to the router (deploy/update)
```

`deploy.sh` only copies files — after it, apply changes with:

```sh
ssh root@192.168.1.1 '/etc/init.d/oc-vpn restart'
```

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
