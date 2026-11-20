#!/bin/sh
# Turn a Wi-Fi/Ethernet Canon PIXMA / MegaTank (or other driverless IPP printer)
# into an AirPrint printer for iPhone/iPad, using a Debian/Ubuntu/Raspberry Pi
# box on the same network. No USB cable, no PC left on.
#
# Usage (as root):
#   sudo ./install.sh PRINTER_IP [options]
#
# Options:
#   --queue NAME        CUPS queue name            (default: Canon_AirPrint)
#   --name "TEXT"       name shown on the iPhone   (default: "Canon AirPrint")
#   --location "TEXT"   location note              (default: "Home")
#   --iface IFACE       advertise only on this LAN interface (recommended with Docker)
#   --mask-colord       disable colord if it makes every job wait ~25-50 s
#   --stock-ipp         use CUPS's normal ipp:// backend instead of canondirect
#
# License: MIT
set -eu

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
[ $# -ge 1 ] || die "usage: sudo ./install.sh PRINTER_IP [--queue Q] [--name N] [--iface IF] [--mask-colord]"

PRINTER_IP="$1"; shift
QUEUE="Canon_AirPrint"
NAME="Canon AirPrint"
LOCATION="Home"
IFACE=""
MASK_COLORD=0
STOCK_IPP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --queue) QUEUE="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --iface) IFACE="$2"; shift 2 ;;
    --mask-colord) MASK_COLORD=1; shift ;;
    --stock-ipp) STOCK_IPP=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$QUEUE" in *[!A-Za-z0-9_-]*|"") die "--queue may only contain letters, digits, _ and -" ;; esac

HERE=$(cd "$(dirname "$0")" && pwd)
URI_IPP="ipp://$PRINTER_IP/ipp/print"

echo "==> Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq cups cups-filters cups-ipp-utils avahi-daemon avahi-utils >/dev/null

echo "==> Checking the printer answers IPP at $URI_IPP"
ipptool -T 15 -q "$URI_IPP" get-printer-attributes.test \
  || die "printer did not answer IPP. Check its IP, Wi-Fi signal, and that IPP is enabled."

echo "==> Generating a driverless PPD"
PPD=$(mktemp /tmp/airprint-ppd.XXXXXX)
driverless "$URI_IPP" > "$PPD" || die "driverless could not build a PPD for this printer"
grep -q '^\*PPD-Adobe' "$PPD" || die "generated PPD looks invalid"

if [ "$STOCK_IPP" -eq 1 ]; then
  DEVICE_URI="$URI_IPP"
else
  echo "==> Installing the canondirect backend"
  install -m 0755 -o root -g root "$HERE/backend/canondirect" /usr/lib/cups/backend/canondirect
  DEVICE_URI="canondirect://$PRINTER_IP/ipp/print"
fi

echo "==> Configuring CUPS"
cp -n /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak-airprint 2>/dev/null || true
cupsctl --share-printers --remote-any
# CUPS's own DNS-SD advertisement makes iOS use ipps (TLS), which can stall cupsd.
# We advertise with a static Avahi service over plain IPP instead.
if grep -q '^BrowseLocalProtocols' /etc/cups/cupsd.conf; then
  sed -i 's/^BrowseLocalProtocols.*/BrowseLocalProtocols none/' /etc/cups/cupsd.conf
else
  echo 'BrowseLocalProtocols none' >> /etc/cups/cupsd.conf
fi
systemctl restart cups

lpadmin -p "$QUEUE" -D "$NAME" -L "$LOCATION" -v "$DEVICE_URI" -P "$PPD" \
  -o printer-is-shared=true -o printer-error-policy=retry-job -E
rm -f "$PPD"

echo "==> Writing the AirPrint (Avahi) service"
COLOR=F
grep -q '^\*ColorModel RGB' "/etc/cups/ppd/$QUEUE.ppd" && COLOR=T
if [ "$COLOR" = T ]; then
  URF="V1.4,CP1,W8,SRGB24,RS300-600"
else
  URF="V1.4,CP1,W8,RS300-600"
fi
UUID=$(cat /proc/sys/kernel/random/uuid)
SERVICE="/etc/avahi/services/airprint-$QUEUE.service"
# XML-escape, then escape \ | & so the value is safe in a sed replacement
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/[\\|&]/\\&/g'; }
sed -e "s|@NAME@|$(esc "$NAME")|g" \
    -e "s|@QUEUE@|$QUEUE|g" \
    -e "s|@LOCATION@|$(esc "$LOCATION")|g" \
    -e "s|@URF@|$URF|g" \
    -e "s|@UUID@|$UUID|g" \
    -e "s|@COLOR@|$COLOR|g" \
    "$HERE/avahi/airprint.service.template" > "$SERVICE"
chmod 644 "$SERVICE"

if [ -n "$IFACE" ]; then
  echo "==> Restricting Avahi to interface $IFACE"
  cp -n /etc/avahi/avahi-daemon.conf /etc/avahi/avahi-daemon.conf.bak-airprint 2>/dev/null || true
  if grep -q '^#\{0,1\}allow-interfaces=' /etc/avahi/avahi-daemon.conf; then
    sed -i "s/^#\{0,1\}allow-interfaces=.*/allow-interfaces=$IFACE/" /etc/avahi/avahi-daemon.conf
  else
    sed -i "/^\[server\]/a allow-interfaces=$IFACE" /etc/avahi/avahi-daemon.conf
  fi
fi

if [ "$MASK_COLORD" -eq 1 ]; then
  echo "==> Masking colord"
  systemctl mask colord >/dev/null 2>&1 || true
fi

systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
systemctl restart avahi-daemon cups

echo
echo "Done. On the iPhone: Share > Print > \"$NAME\"."
echo "Check the advertisement with:  avahi-browse -rt _ipp._tcp"
