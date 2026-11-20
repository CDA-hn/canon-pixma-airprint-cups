# Troubleshooting

Commands run on the Linux server. Replace `PRINTER_IP` and `Canon_AirPrint`.

## Is the printer reachable and idle?

```bash
ping -c 3 PRINTER_IP
ipptool -tv ipp://PRINTER_IP/ipp/print get-printer-attributes.test \
  | grep -E 'printer-state \(|printer-state-reasons|accepting'
```

`spool-area-full-report` plus `printer-is-accepting-jobs = false` means the printer is still holding an earlier job.

## What jobs does the printer itself have?

```bash
ipptool -tv ipp://PRINTER_IP/ipp/print get-jobs.test           | grep -E 'job-(id|state|name) '
ipptool -tv ipp://PRINTER_IP/ipp/print get-completed-jobs.test | grep -E 'job-(id|state-reasons|name) '
```

- A job stuck in `processing` with `job-impressions-completed = 0` points to the chunked-transfer problem. Use the `canondirect` backend.
- `job-canceled-at-device` means the printer dropped the job. Look at the same cause, or at paper/ink errors on the printer.

## Is iOS stuck on TLS?

```bash
sudo grep 'Unable to encrypt connection' /var/log/cups/error_log | tail
ss -tn '( sport = :631 )'      # many ESTAB sockets with a non-zero Recv-Q = cupsd not reading
avahi-browse -rt _ipps._tcp    # your server should NOT appear here after install
```

## What is being advertised?

```bash
avahi-browse -rpt _ipp._tcp | grep '^='
```

You should see your `--name` on your LAN interface only, with `URF=` in the TXT record.

## Jobs take ~50 s to start

```bash
cupsfilter -p /etc/cups/ppd/Canon_AirPrint.ppd -m image/pwg-raster test.pdf 2>&1 >/dev/null | grep ColorManager
```

`Failed to activate service 'org.freedesktop.ColorManager': timed out` means colord is the delay. Re-run the installer with `--mask-colord`, or run `sudo systemctl mask colord`.

## Send a test page straight to the printer (bypassing CUPS)

```bash
cupsfilter -p /etc/cups/ppd/Canon_AirPrint.ppd -m image/pwg-raster test.pdf > test.pwg
DEVICE_URI=canondirect://PRINTER_IP/ipp/print /usr/lib/cups/backend/canondirect 1 me test 1 "" < test.pwg
```
