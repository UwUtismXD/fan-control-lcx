#!/usr/bin/env bash
#
# fan-control.sh — poll iDRAC temperatures and hold the chassis fans at one of
# two fixed duty cycles.
#
#   temp >= TEMP_HIGH  ->  DUTY_HIGH
#   temp <  TEMP_LOW   ->  DUTY_LOW
#   in between         ->  hold whatever we're already at (hysteresis)
#
# The fans stay under manual control at all times. We never hand them back to
# iDRAC's automatic curve: DUTY_HIGH is known to be sufficient for this chassis,
# DUTY_LOW is not, so every uncertain case resolves to DUTY_HIGH rather than to
# iDRAC. That includes losing contact with the BMC and starting up mid-band.
#
# Config comes from /etc/fan-control/fan-control.env (see fan-control.env.example).
# Run it under systemd with fan-control.service, or by hand for a look:
#   sudo IPMI_PASSWORD=... ./fan-control.sh
#
set -uo pipefail

CONF=${FAN_CONTROL_ENV:-/etc/fan-control/fan-control.env}
[[ -r $CONF ]] && . "$CONF"

IDRAC_HOST=${IDRAC_HOST:-192.168.8.120}
IDRAC_USER=${IDRAC_USER:-root}
POLL_INTERVAL=${POLL_INTERVAL:-10}
TEMP_HIGH=${TEMP_HIGH:-90}
TEMP_LOW=${TEMP_LOW:-60}
DUTY_HIGH=${DUTY_HIGH:-20}
DUTY_LOW=${DUTY_LOW:-10}
TEMP_ALARM=${TEMP_ALARM:-95}
FAIL_LIMIT=${FAIL_LIMIT:-3}
REASSERT_CYCLES=${REASSERT_CYCLES:-30}
HEARTBEAT_CYCLES=${HEARTBEAT_CYCLES:-360}
MANAGE_PCIE_OVERRIDE=${MANAGE_PCIE_OVERRIDE:-1}
RESTORE_ON_EXIT=${RESTORE_ON_EXIT:-0}

: "${IPMI_PASSWORD:?IPMI_PASSWORD is not set - put it in $CONF}"
export IPMI_PASSWORD

# -E reads the password from $IPMI_PASSWORD instead of the command line, so it
# never shows up in ps output.
IPMI=(ipmitool -I lanplus -H "$IDRAC_HOST" -U "$IDRAC_USER" -E -N 2 -R 2)

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# What we believe the fans are set to: INIT (not yet established), LOW or HIGH.
mode=INIT

manual_mode() { "${IPMI[@]}" raw 0x30 0x30 0x01 0x00 >/dev/null 2>&1; }
auto_mode()   { "${IPMI[@]}" raw 0x30 0x30 0x01 0x01 >/dev/null 2>&1; }
set_duty()    { "${IPMI[@]}" raw 0x30 0x30 0x02 0xff "$(printf '0x%02x' "$1")" >/dev/null 2>&1; }

# Highest numeric reading from `sdr type temperature`, e.g.
#   Temp | 0Eh | ok | 3.1 | 41 degrees C
# Sensors reading "ns"/"disabled" have no number and are skipped.
max_temp() {
  "${IPMI[@]}" sdr type temperature 2>/dev/null \
    | awk -F'|' '$5 ~ /degrees C/ { gsub(/[^0-9]/, "", $5); if ($5 != "" && $5+0 > m) m = $5+0 }
                 END { if (m) print m; else exit 1 }'
}

# Dell pins the fans to a high floor and ignores every manual duty cycle while
# its third-party PCIe cooling response is active - which it is by default when
# a GPU is present, and which can come back on its own. Without this the rest of
# the script is inert, so we check it and put it back.
pcie_override_active() {
  local out
  out=$("${IPMI[@]}" raw 0x30 0xce 0x01 0x16 0x05 0x00 0x00 0x00 2>/dev/null) || return 1
  # Response is "16 05 00 00 00 05 00 XX 00 00"; XX is 01 when disabled.
  [[ $(awk '{print $8}' <<< "$out") != "01" ]]
}

disable_pcie_override() {
  "${IPMI[@]}" raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00 >/dev/null 2>&1
}

check_pcie_override() {
  [[ $MANAGE_PCIE_OVERRIDE == 1 ]] || return 0
  if pcie_override_active; then
    log "third-party PCIe cooling response is active - fans would be pinned to Dell's floor; disabling it"
    disable_pcie_override && log "PCIe cooling override disabled" || log "ERROR: could not disable PCIe cooling override"
  fi
}

go_manual() {
  local duty=$1 label=$2
  if manual_mode && set_duty "$duty"; then
    mode=$label
    return 0
  fi
  return 1
}

cleanup() {
  trap - EXIT
  # Off by default: stopping the service leaves the fans where they are rather
  # than surrendering them to iDRAC's curve.
  if [[ $RESTORE_ON_EXIT == 1 ]]; then
    log "shutting down - returning fans to iDRAC automatic control"
    auto_mode
  else
    log "shutting down - leaving fans under manual control at ${mode}"
  fi
}
trap cleanup EXIT
# The signal traps must exit; otherwise the handler returns into the loop and
# `systemctl stop` hangs until systemd loses patience and SIGKILLs us.
trap 'exit 143' TERM
trap 'exit 130' INT

log "starting: ${IDRAC_HOST} poll=${POLL_INTERVAL}s  >=${TEMP_HIGH}C -> ${DUTY_HIGH}%  <${TEMP_LOW}C -> ${DUTY_LOW}%  alarm=${TEMP_ALARM}C"

check_pcie_override

fails=0
cycle=0
alarm=0
# How often to re-try asserting control while we cannot read temperatures.
blind_retry=$(( REASSERT_CYCLES > 0 ? REASSERT_CYCLES : 30 ))

while :; do
  if ! temp=$(max_temp); then
    ((fails++))
    if (( fails < FAIL_LIMIT )); then
      log "WARN: temperature read failed ($fails/$FAIL_LIMIT)"
    else
      if (( fails == FAIL_LIMIT )); then
        log "ERROR: no temperature reading in $fails tries - flying blind, forcing ${DUTY_HIGH}%"
      fi
      # Blind means we cannot tell hot from cold, so sit at the duty that is
      # always sufficient and keep re-asserting it until readings come back.
      if (( (fails - FAIL_LIMIT) % blind_retry == 0 )); then
        go_manual "$DUTY_HIGH" HIGH || true
      fi
    fi
    sleep "$POLL_INTERVAL"
    continue
  fi

  if (( fails >= FAIL_LIMIT )); then
    log "iDRAC responding again (${temp}C) - resuming normal control"
    mode=INIT
  fi
  fails=0
  ((cycle++))

  if (( temp >= TEMP_HIGH )); then
    if [[ $mode != HIGH ]]; then
      log "${temp}C >= ${TEMP_HIGH}C - fans to ${DUTY_HIGH}%"
      go_manual "$DUTY_HIGH" HIGH || log "ERROR: failed to set ${DUTY_HIGH}%"
    fi
  elif (( temp < TEMP_LOW )); then
    if [[ $mode != LOW ]]; then
      log "${temp}C < ${TEMP_LOW}C - fans to ${DUTY_LOW}%"
      go_manual "$DUTY_LOW" LOW || log "ERROR: failed to set ${DUTY_LOW}%"
    fi
  elif [[ $mode == INIT ]]; then
    # First pass, or recovery, landing inside the hysteresis band. We have no
    # history to hold, so take the duty that is always enough.
    log "startup at ${temp}C (between ${TEMP_LOW} and ${TEMP_HIGH}) - fans to ${DUTY_HIGH}%"
    go_manual "$DUTY_HIGH" HIGH || log "ERROR: failed to set ${DUTY_HIGH}%"
  fi

  # Loud log if it climbs past where DUTY_HIGH should have held it. Nothing
  # changes - we stay at DUTY_HIGH under manual control - but it is worth
  # knowing about in the journal.
  if (( temp >= TEMP_ALARM )); then
    if (( alarm == 0 )); then
      log "ALARM: ${temp}C >= ${TEMP_ALARM}C while holding ${DUTY_HIGH}% - staying manual, check airflow"
      alarm=1
    fi
  elif (( alarm == 1 && temp < TEMP_HIGH )); then
    log "alarm cleared (${temp}C)"
    alarm=0
  fi

  # iDRAC drops back to its own curve after some events, so periodically
  # re-issue manual mode and the duty we think we're holding.
  if (( REASSERT_CYCLES > 0 && cycle % REASSERT_CYCLES == 0 )); then
    check_pcie_override
    case $mode in
      LOW)  go_manual "$DUTY_LOW" LOW ;;
      HIGH) go_manual "$DUTY_HIGH" HIGH ;;
    esac
  fi

  if (( HEARTBEAT_CYCLES > 0 && cycle % HEARTBEAT_CYCLES == 0 )); then
    log "alive: ${temp}C, mode=${mode}"
  fi

  sleep "$POLL_INTERVAL"
done
