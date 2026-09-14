#!/bin/bash
# fanstat.sh - one-shot look at what the fans and sensors are actually doing.
set -a; . /etc/fan-control/fan-control.env; set +a
I=(ipmitool -I lanplus -H "$IDRAC_HOST" -U "$IDRAC_USER" -E)
echo "== temperatures =="
"${I[@]}" sdr type temperature | awk -F'|' '{printf "  %-16s %s\n", $1, $5}'
echo "== fans =="
"${I[@]}" sdr type fan | awk -F'|' '{printf "  %-16s %s\n", $1, $5}'
echo "== third-party PCIe cooling response =="
printf "  raw: "; "${I[@]}" raw 0x30 0xce 0x01 0x16 0x05 0x00 0x00 0x00
echo "== daemon =="
systemctl is-active fan-control.service | sed 's/^/  /'
