#!/usr/bin/env bash
# Run from any directory. Credentials never enter the repository or stdout.
set -euo pipefail

SERVER_HOST="${KIKI_SERVER_HOST:-43.138.219.160}"
PUBLIC_ORIGIN="https://kiki.group"
IDENTITY_PATH="${KIKI_SSH_IDENTITY:-$HOME/.ssh/kikitalk_server.pem}"
KNOWN_HOSTS_PATH="${KIKI_KNOWN_HOSTS:-$HOME/.ssh/kikitalk_known_hosts}"
ENV_PATH="${KIKI_SERVER_ENV:-$HOME/.config/kikitalk/server.env}"
BACKEND_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH_OPTIONS=(-i "$IDENTITY_PATH" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS_PATH")

test -r "$IDENTITY_PATH"
test -r "$KNOWN_HOSTS_PATH"
ARCHIVE_PATH="$(mktemp -t kikitalk-source.XXXXXX)"
trap 'rm -f "$ARCHIVE_PATH"' EXIT
COPYFILE_DISABLE=1 tar --no-xattrs --exclude=__pycache__ -czf "$ARCHIVE_PATH" -C "$BACKEND_DIR" app requirements.txt deploy/kikitalk.service

ssh "${SSH_OPTIONS[@]}" "root@$SERVER_HOST" 'set -eu
id kikitalk >/dev/null 2>&1 || useradd --system --home-dir /var/lib/kikitalk --shell /sbin/nologin kikitalk
install -d -m 755 /opt/kikitalk
install -d -o kikitalk -g kikitalk -m 700 /var/lib/kikitalk
install -d -o root -g kikitalk -m 750 /etc/kikitalk
umask 077'
# Preserve the existing production credentials on ordinary updates.
if ! ssh "${SSH_OPTIONS[@]}" "root@$SERVER_HOST" 'test -s /etc/kikitalk/server.env'; then
  test -r "$ENV_PATH"
  scp "${SSH_OPTIONS[@]}" "$ENV_PATH" "root@$SERVER_HOST:/etc/kikitalk/server.env"
fi
scp "${SSH_OPTIONS[@]}" "$ARCHIVE_PATH" "root@$SERVER_HOST:/opt/kikitalk/source.tar.gz"

ssh "${SSH_OPTIONS[@]}" "root@$SERVER_HOST" 'set -eu
umask 022
tar -xzf /opt/kikitalk/source.tar.gz -C /opt/kikitalk
rm /opt/kikitalk/source.tar.gz
python3 -m venv /opt/kikitalk/venv
/opt/kikitalk/venv/bin/python -m pip install --quiet --disable-pip-version-check -r /opt/kikitalk/requirements.txt
chmod -R a+rX /opt/kikitalk
chmod 600 /etc/kikitalk/server.env
install -m 644 /opt/kikitalk/deploy/kikitalk.service /etc/systemd/system/kikitalk.service
systemctl daemon-reload
systemctl enable --now kikitalk
systemctl restart kikitalk
systemctl is-active kikitalk'

# TLS and the public hostname are owned by Nginx, not the Python process.
curl --noproxy '*' --proto '=https' --tlsv1.2 --fail --silent --show-error \
  --retry 3 --retry-connrefused --retry-delay 1 --connect-timeout 10 --max-time 20 \
  "$PUBLIC_ORIGIN/health"
