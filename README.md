# fan-control-lcx

IPMI fan control for a Dell PowerEdge R730 (iDRAC8), run as a daemon from an LXC
container on the Proxmox host rather than on the server itself.

The chassis fans are held under **manual** control at all times, at one of two fixed
duty cycles picked by the hottest sensor iDRAC reports:

| temperature | fans |
|---|---|
| `>= TEMP_HIGH` | `DUTY_HIGH` |
| `< TEMP_LOW` | `DUTY_LOW` |
| in between | hold whatever is currently set (hysteresis) |

Control is never handed back to iDRAC's automatic curve. `DUTY_HIGH` is known to be
sufficient for this chassis and `DUTY_LOW` is not, so every uncertain case — a failed
BMC read, a start-up landing inside the hysteresis band — resolves to `DUTY_HIGH`.

## Why a GPU makes this necessary

With a third-party PCIe card present, iDRAC turns on its "third-party PCIe cooling
response", pins the fans to a loud floor, and **silently ignores every manual duty
cycle**. The daemon checks that setting at start-up and periodically, and switches it
back off if it returns — without that, the rest of the script is inert.

## Files

| File | Purpose |
|---|---|
| `fan-control.sh` | the daemon — install to `/usr/local/bin/` |
| `fan-control.service` | systemd unit |
| `fan-control.env.example` | config template — copy to `/etc/fan-control/fan-control.env` |
| `fanstat.sh` | one-shot look at temperatures, fan RPM, PCIe override state, daemon status |
| `sweep.sh` | steps through duty cycles and records temperatures, for finding the minimum safe speed |

## Install

```sh
install -m 755 fan-control.sh fanstat.sh /usr/local/bin/
install -m 644 fan-control.service /etc/systemd/system/
install -d /etc/fan-control
install -m 600 fan-control.env.example /etc/fan-control/fan-control.env
# edit /etc/fan-control/fan-control.env - at minimum IDRAC_HOST and IPMI_PASSWORD
systemctl daemon-reload
systemctl enable --now fan-control.service
```

Requires `ipmitool` and network reach to the iDRAC. The password is passed via
`$IPMI_PASSWORD` (`ipmitool -E`) so it never appears in `ps` output; keep
`fan-control.env` at mode `600`.

## Configuration

Every setting is documented in `fan-control.env.example`. The ones worth knowing:

- `TEMP_HIGH` / `TEMP_LOW` — the hysteresis band. A narrow band with a `DUTY_LOW` that
  cannot hold the load makes the fans cycle up and down every few minutes, which is
  more annoying than simply running a little faster.
- `MANAGE_PCIE_OVERRIDE` — keep at `1` on a machine with a GPU (see above).
- `RESTORE_ON_EXIT` — `0` leaves the fans where they are when the service stops. Set to
  `1` only if you want iDRAC's curve back on shutdown.
- `REASSERT_CYCLES` — iDRAC drops back to its own curve after some events, so manual
  mode and the current duty are re-issued this often.
