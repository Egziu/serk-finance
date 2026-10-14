#!/bin/sh
# Installs Serk Finance from this folder: /opt/serk-finance (program), /var/lib/serk-finance
# (company data, readable only by the service account) and the serk-finance systemd service.
#   sudo ./install.sh [--local-only]
set -eu
if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo: sudo ./install.sh" >&2; exit 1; fi
here=$(cd "$(dirname "$0")" && pwd)
local_only=""
[ "${1:-}" = "--local-only" ] && local_only=" --local-only"
command -v systemctl >/dev/null || { echo "systemd is required." >&2; exit 1; }
if ! id serk-finance >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/serk-finance --shell /usr/sbin/nologin serk-finance
fi
systemctl stop serk-finance 2>/dev/null || true
mkdir -p /opt/serk-finance
cp -a "$here/serk-server" "$here/web" "$here/pgsql" "$here/README-INSTALL.txt" "$here/LICENSE-INSTALL.txt" "$here/THIRD-PARTY-NOTICES.txt" /opt/serk-finance/
chown -R root:root /opt/serk-finance && chmod -R go-w /opt/serk-finance
install -d -m 0700 -o serk-finance -g serk-finance /var/lib/serk-finance
install -m 0755 "$here/serk-finance" /usr/local/bin/serk-finance
sed "s#--data /var/lib/serk-finance#--data /var/lib/serk-finance${local_only}#" "$here/serk-finance.service" > /etc/systemd/system/serk-finance.service
systemctl daemon-reload
systemctl enable --now serk-finance
echo "Waiting for Serk Finance to start (the first start prepares the database)..."
i=0
until curl -fsS http://127.0.0.1:8080/health/ready >/dev/null 2>&1 || [ $i -ge 120 ]; do sleep 1; i=$((i+1)); done
echo
echo "Serk Finance is running: http://localhost:8080"
if [ -f /var/lib/serk-finance/setup-token.txt ]; then
  echo "Open http://localhost:8080/setup on this computer to create your company,"
  echo "or from another computer: http://$(hostname):8080/setup?token=$(cat /var/lib/serk-finance/setup-token.txt)"
fi
echo "Back up:   sudo serk-finance backup"
echo "Logs:      journalctl -u serk-finance"
