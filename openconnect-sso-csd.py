#!/usr/bin/env python3
"""openconnect-sso with CSD/hostscan support.

Some ASAs demand a hostscan ("Cisco Secure Desktop") report even for a
SAML tunnel-group: the aggregate-auth init response carries a <host-scan>
node, and without a posted scan the final auth-reply fails with
    error id=13: Cisco Secure Desktop not installed on the client

Stock openconnect-sso ignores <host-scan> entirely, so this wrapper
monkeypatches Authenticator._start_authentication to run the csd-post.sh
trojan (the same one openconnect itself uses) between the init request and
the browser SAML step, then delegates to the normal openconnect-sso CLI.

Autofill is disabled entirely: credentials are forced to None, so there
are no password/TOTP prompts, nothing touches the OS keyring, and the
browser performs no autologin -- the login form is filled by hand in the
browser window. (The config.load patch matters even without --user: a
credentials block saved in config.toml by stock openconnect-sso runs
would otherwise bring the prompts and the keyring back.)

Expected environment (set by vpn-auth-sso.sh):
    CSD_WRAPPER  path to csd-post.sh (skips the scan when unset)
    CSD_SHA256   pin-sha256 of the server public key, without the prefix
                 (csd-post.sh falls back to CA validation when empty)

Run with the interpreter of the openconnect-sso installation:
    <venv>/bin/python openconnect-sso-csd.py <openconnect-sso args>
"""

import os
import subprocess
import sys
from urllib.parse import urlparse

import structlog
from lxml import etree

from openconnect_sso import authenticator as auth_mod
from openconnect_sso import config as config_mod
from openconnect_sso.cli import main

logger = structlog.get_logger()

# host-scan-token from the last CSD run; _create_auth_finish_request is a
# module-level function, so the value is passed via this global.
_csd_state = {"token": None}


# --- no autofill, no prompts, no keyring --------------------------------------
# Stock openconnect-sso builds a Credentials object from --user or from the
# credentials block it saved to config.toml on previous runs; that object
# triggers getpass prompts and OS keyring reads/writes, and drives the
# browser autologin. Dropping it disables all of that: the login form is
# filled by hand in the browser window.

_orig_config_load = config_mod.load


def load_without_credentials():
    cfg = _orig_config_load()
    cfg.credentials = None
    return cfg


config_mod.load = load_without_credentials


def run_csd_if_needed(self, content):
    """Run the CSD wrapper if the response demands a hostscan.

    Returns True when a scan was posted: the caller must then REPEAT the
    init request -- the ASA only re-evaluates the hostscan status while
    processing an init, so an auth-reply in the original aggauth session
    still fails with error id=13 (this mirrors what openconnect does:
    trojan first, then the auth request again).
    """
    wrapper = os.environ.get("CSD_WRAPPER")
    if not wrapper:
        return False
    try:
        root = etree.fromstring(content)
    except etree.XMLSyntaxError:
        return False
    ticket = root.findtext(".//host-scan-ticket")
    if not ticket:
        return False
    token = root.findtext(".//host-scan-token") or ""

    env = dict(os.environ)
    env["CSD_HOSTNAME"] = urlparse(self.host.vpn_url).hostname
    logger.info("Server requires hostscan, running CSD wrapper",
                wrapper=wrapper, ticket=ticket)
    # openconnect calls the wrapper as: wrapper <token> -ticket T -stub 0 ...
    # (csd-post.sh shifts away $1 and re-fetches the token itself).
    # stdout must not leak into ours: --authenticate shell output is parsed.
    result = subprocess.run(
        [wrapper, token, "-ticket", ticket, "-stub", "0"],
        env=env, stdout=sys.stderr, stderr=sys.stderr,
    )
    if result.returncode != 0:
        logger.warning("CSD wrapper exited non-zero", rc=result.returncode)
    if token:
        # openconnect keeps the hostscan token as a cookie for the rest of
        # the auth conversation and echoes it as <host-scan-token> in the
        # auth-reply (auth.c: run_csd_script / xmlpost_append_form_opts).
        self.session.cookies.set("sdesktop", token, domain=env["CSD_HOSTNAME"])
        _csd_state["token"] = token
    return True


def start_authentication_with_csd(self):
    for attempt in (1, 2):
        request = auth_mod._create_auth_init_request(
            self.host, self.host.vpn_url, self.version
        )
        logger.debug("Sending auth init request", content=request)
        response = self.session.post(self.host.vpn_url, request)
        logger.debug("Auth init response received", content=response.content)
        if attempt == 1 and run_csd_if_needed(self, response.content):
            logger.info("Hostscan posted, repeating the init request")
            continue
        return auth_mod.parse_response(response)


_orig_create_finish = auth_mod._create_auth_finish_request


def create_finish_with_host_scan_token(host, auth_info, sso_token, version):
    """The ASA validates the hostscan via a <host-scan-token> element in the
    auth-reply; without it the reply fails with error id=13 even though the
    scan was posted and accepted (TOKEN_SUCCESS)."""
    body = _orig_create_finish(host, auth_info, sso_token, version)
    token = _csd_state["token"]
    if not token:
        return body
    root = etree.fromstring(body)
    el = etree.SubElement(root, "host-scan-token")
    el.text = token
    return etree.tostring(
        root, pretty_print=True, xml_declaration=True, encoding="UTF-8"
    )


auth_mod.Authenticator._start_authentication = start_authentication_with_csd
auth_mod._create_auth_finish_request = create_finish_with_host_scan_token

if __name__ == "__main__":
    sys.exit(main())
