#!/bin/sh
# Removes the Serk Finance program and service. Company data in /var/lib/serk-finance is kept
# unless --purge is given.
set -eu
if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo." >&2; exit 1; fi
systemctl disable --now serk-finance 2>/dev/null || true
rm -f /etc/systemd/system/serk-finance.service /usr/local/bin/serk-finance
systemctl daemon-reload
rm -rf /opt/serk-finance
if [ "${1:-}" = "--purge" ]; then
  rm -rf /var/lib/serk-finance
  userdel serk-finance 2>/dev/null || true
  echo "Serk Finance and all company data were removed."
else
  echo "Serk Finance was removed. Company data is kept in /var/lib/serk-finance."
fi
