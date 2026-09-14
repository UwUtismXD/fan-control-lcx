#!/bin/bash
# Steady-state sweep: hold a duty, watch where temps settle.
# Aborts to 30% if anything crosses ABORT_TEMP.
set -a; . /etc/fan-control/fan-control.env; set +a
I=(ipmitool -I lanplus -H "$IDRAC_HOST" -U "$IDRAC_USER" -E)
ABORT_TEMP=${ABORT_TEMP:-88}

hottest() { "${I[@]}" sdr type temperature 2>/dev/null | grep -o '[0-9]* degrees' | sort -rn | head -1 | cut -d' ' -f1; }
rpm()     { "${I[@]}" sdr type fan 2>/dev/null | grep '^Fan1' | grep -o '[0-9]* RPM'; }
setduty() { "${I[@]}" raw 0x30 0x30 0x01 0x00 >/dev/null 2>&1; "${I[@]}" raw 0x30 0x30 0x02 0xff "$1" >/dev/null 2>&1; }

for step in "20:0x14:8" "10:0x0a:10"; do
  pct=${step%%:*}; rest=${step#*:}; hex=${rest%%:*}; n=${rest##*:}
  echo "=== holding ${pct}% ==="
  setduty "$hex"
  for ((i=1; i<=n; i++)); do
    sleep 30
    t=$(hottest); r=$(rpm)
    echo "  ${pct}%  t+$((i*30))s  hottest=${t}C  Fan1=${r}"
    if [[ -n $t ]] && (( t >= ABORT_TEMP )); then
      echo "  !! ${t}C >= ${ABORT_TEMP}C - aborting sweep, going to 30%"
      setduty 0x1e
      exit 1
    fi
  done
done
echo "=== sweep done - leaving fans at 20% ==="
setduty 0x14
