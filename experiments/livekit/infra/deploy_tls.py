#!/usr/bin/env python3
"""Install the supplied TLS certificate on the isolated furby.top experiment host."""
from datetime import datetime, timezone
from pathlib import Path
import shlex
import subprocess
import sys


HERE = Path(__file__).resolve().parent
HOST = "furby-livekit-lab"
TLS = Path.home() / ".config/kikitalk-livekit-lab/tls/furby.top"
CERT = TLS / "furby.top_bundle.crt"
KEY = TLS / "furby.top.key"
SSH = ["ssh", "-F", str(HERE / "ssh_config"), HOST]


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def remote(script):
    run(SSH + ["sh -se"], input=script, text=True)


def main():
    for path in (CERT, KEY, HERE / "furby.top.conf", HERE / "haproxy.cfg"):
        if not path.is_file():
            raise SystemExit(f"Missing required local file: {path}")
    if KEY.stat().st_mode & 0o077:
        raise SystemExit("TLS private key must be readable only by its owner (chmod 600)")
    run(["openssl", "x509", "-in", str(CERT), "-noout", "-checkhost", "furby.top"])
    run(["openssl", "x509", "-in", str(CERT), "-noout", "-checkend", "604800"])
    cert_public = run(["openssl", "x509", "-in", str(CERT), "-pubkey", "-noout"], capture_output=True).stdout
    key_public = run(["openssl", "pkey", "-in", str(KEY), "-pubout"], capture_output=True).stdout
    if cert_public != key_public:
        raise SystemExit("Certificate does not match TLS private key")

    # Refuse deployment if the dedicated alias is ever redirected to production.
    effective = run(["ssh", "-G", "-F", str(HERE / "ssh_config"), HOST], capture_output=True, text=True).stdout
    if "hostname 139.224.50.108\n" not in effective:
        raise SystemExit("Experiment alias must resolve to 139.224.50.108")
    remote("""set -eu
test "$(id -u)" = 0
if ! command -v nginx >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
fi
install -d -m 700 /etc/nginx/tls/furby.top /var/backups/furby-livekit-lab
test -f /etc/livekit-lab/livekit.yaml
command -v haproxy >/dev/null
install -d -m 700 /etc/haproxy/private
""")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = "/var/backups/furby-livekit-lab/tls-" + stamp
    staging = run(SSH + ["umask 077; mktemp -d /root/furby-tls.XXXXXXXX"], capture_output=True, text=True).stdout.strip()
    if not staging.startswith("/root/furby-tls.") or any(c not in "/.-_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" for c in staging):
        raise SystemExit("Unexpected remote staging directory")
    backup_ready = False
    managed = (
        ("fullchain.pem", "/etc/nginx/tls/furby.top/fullchain.pem"),
        ("privkey.pem", "/etc/nginx/tls/furby.top/privkey.pem"),
        ("site-available", "/etc/nginx/sites-available/furby.top"),
        ("site-enabled", "/etc/nginx/sites-enabled/furby.top"),
        ("edge-cert.pem", "/etc/haproxy/private/furby.top.pem"),
        ("edge.cfg", "/etc/haproxy/haproxy.cfg"),
    )
    try:
        for local, name in ((CERT, "fullchain.pem"), (KEY, "privkey.pem"), (HERE / "furby.top.conf", "furby.top.conf"), (HERE / "haproxy.cfg", "haproxy.cfg")):
            run(["scp", "-q", "-F", str(HERE / "ssh_config"), str(local), f"{HOST}:{staging}/{name}"])
        # Record files, symlinks and absence before modifying anything managed.
        snapshot = f"set -eu\numask 077\ntest ! -e {shlex.quote(backup)}\nmkdir -m 700 {shlex.quote(backup)}\n"
        for name, path in managed:
            snapshot += f"if test -e {path} || test -L {path}; then cp -a {path} {backup}/{name}; fi\n"
        remote(snapshot)
        backup_ready = True
        remote(f"""set -eu
install -m 644 {shlex.quote(staging)}/fullchain.pem /etc/nginx/tls/furby.top/fullchain.pem
install -m 600 {shlex.quote(staging)}/privkey.pem /etc/nginx/tls/furby.top/privkey.pem
install -m 644 {shlex.quote(staging)}/furby.top.conf /etc/nginx/sites-available/furby.top
ln -sfn /etc/nginx/sites-available/furby.top /etc/nginx/sites-enabled/furby.top
install -m 644 {shlex.quote(staging)}/haproxy.cfg /etc/haproxy/haproxy.cfg
# Separate PEM blocks even when the certificate archive omitted its final newline.
{{ cat {shlex.quote(staging)}/fullchain.pem; printf '\\n'; cat {shlex.quote(staging)}/privkey.pem; printf '\\n'; }} > {shlex.quote(staging)}/edge.pem
install -m 600 {shlex.quote(staging)}/edge.pem /etc/haproxy/private/furby.top.pem
nginx -t
haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl enable --now nginx
systemctl reload nginx
systemctl reload haproxy
systemctl is-active nginx
systemctl is-active haproxy
stat -c '%U:%G %a %n' /etc/nginx/tls/furby.top /etc/nginx/tls/furby.top/privkey.pem
""")
        # System CA validation also catches a syntactically valid but bad chain.
        run(["curl", "--noproxy", "*", "--resolve", "furby.top:443:139.224.50.108", "--fail", "--silent", "--show-error", "--connect-timeout", "10", "--max-time", "20", "https://furby.top/health"])
    except BaseException:
        if backup_ready:
            restore = "set -eu\n"
            for name, path in managed:
                restore += f"rm -f {path}\nif test -e {backup}/{name} || test -L {backup}/{name}; then cp -a {backup}/{name} {path}; fi\n"
            restore += "nginx -t\nhaproxy -c -f /etc/haproxy/haproxy.cfg\nsystemctl reload nginx\nsystemctl reload haproxy\n"
            try:
                remote(restore)
                print("Deployment failed; previous TLS files and site state restored.", file=sys.stderr)
            except subprocess.CalledProcessError:
                print(f"Automatic restore failed. Restricted server backup: {backup}", file=sys.stderr)
        raise
    finally:
        try:
            remote("rm -rf -- " + shlex.quote(staging))
        except subprocess.CalledProcessError:
            print(f"Remote staging cleanup failed; remove {staging} after reconnecting.", file=sys.stderr)


if __name__ == "__main__":
    main()
