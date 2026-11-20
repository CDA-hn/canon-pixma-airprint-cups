#!/bin/sh
# Remove what install.sh added.  Usage: sudo ./uninstall.sh [--queue NAME]
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
QUEUE="Canon_AirPrint"
[ "${1:-}" = "--queue" ] && QUEUE="$2"

lpadmin -x "$QUEUE" 2>/dev/null || true
rm -f "/etc/avahi/services/airprint-$QUEUE.service"
# Remove the backend only if no other queue uses it
if ! lpstat -v 2>/dev/null | grep -q 'canondirect://'; then
  rm -f /usr/lib/cups/backend/canondirect
fi
[ -f /etc/cups/cupsd.conf.bak-airprint ] && cp /etc/cups/cupsd.conf.bak-airprint /etc/cups/cupsd.conf
[ -f /etc/avahi/avahi-daemon.conf.bak-airprint ] && cp /etc/avahi/avahi-daemon.conf.bak-airprint /etc/avahi/avahi-daemon.conf
systemctl unmask colord >/dev/null 2>&1 || true
systemctl restart cups avahi-daemon
echo "Removed queue $QUEUE and its AirPrint advertisement."
