# host-setup

Scripts that prepare a Linux host (Debian/Ubuntu/Mint family) to run HashGG in
Docker. None of these are used by the StartOS packages — they exist only for
users running HashGG as a plain Docker container on their own Linux box.

## Current scripts

### [`install-datum-gateway.sh`](./install-datum-gateway.sh)

One script, on-demand use. It doesn't force a systemd daemon — a lot of users
run `bitcoin-qt` interactively rather than `bitcoind`-as-a-service, and Datum
needs Knots to be running anyway, so an always-on daemon doesn't buy them much.

Run it as your **normal user** (not root). It prompts for `sudo` only when it
genuinely needs root (apt-get, systemctl, writing under `/usr/local` or `/etc`).

```bash
bash host-setup/install-datum-gateway.sh           # interactive menu
bash host-setup/install-datum-gateway.sh build     # direct command
bash host-setup/install-datum-gateway.sh help
```

Commands:

| Command            | What it does                                                                       | Root? |
|--------------------|------------------------------------------------------------------------------------|-------|
| `check-knots`      | Parses `bitcoin.conf`, flags missing settings Datum needs (RPC + `blocknotify`), prints a paste-in for the gaps, and live-probes the RPC. | no |
| `build`            | Clone / update source, build, install binary to `~/.local/bin/datum_gateway`.      | sudo for `apt install` only |
| `configure`        | Interactive prompts; writes `~/.config/datum_gateway/datum_gateway.json`.          | no |
| `run`              | Launches Datum in the foreground using the user-local binary + config. Ctrl-C to stop. | no |
| `open-firewall`    | Adds a ufw rule so HashGG-in-Docker (on `172.16.0.0/12`) can reach Datum's stratum port. One-time per host. | yes (sudo) |
| `install-daemon`   | Promotes the user-local install to a systemd service + `datum` system user. Calls `open-firewall` as part of setup. | yes (sudo) |
| `uninstall-daemon` | Removes the systemd service and system files. Leaves user-local files alone.       | yes (sudo) |
| `uninstall`        | Removes everything (user + system).                                                | yes (sudo) |
| `status`           | Shows what's installed where and whether Knots RPC is reachable.                   | no |

### Typical workflows

**bitcoin-qt user (the common case — Datum on demand, HashGG in Docker):**

```bash
bash host-setup/install-datum-gateway.sh check-knots    # first — flags bitcoin.conf gaps
# (edit bitcoin.conf with the lines it prints, restart bitcoin-qt)
bash host-setup/install-datum-gateway.sh build          # once
bash host-setup/install-datum-gateway.sh configure      # once (re-run to change settings)
bash host-setup/install-datum-gateway.sh open-firewall  # once per host, if ufw is active
# later, any time you want to mine:
bash host-setup/install-datum-gateway.sh run            # Ctrl-C to stop
```

**bitcoind-as-service user:**

```bash
bash host-setup/install-datum-gateway.sh check-knots
bash host-setup/install-datum-gateway.sh build
bash host-setup/install-datum-gateway.sh configure
bash host-setup/install-datum-gateway.sh install-daemon   # includes the firewall rule
```

### Iterative

The script is expected to be tweaked as we hit reality. Known uncertain bits
are flagged inline with `TODO`/`warn`:

- `DATUM_REF=master` — pin to a release tag once we've validated one works end-to-end.
- apt dep list is a best guess. Missing headers will surface in the first build run.
- Datum's config field names (`bitcoind.rpcurl`, `stratum.listen_addr`, etc.) are
  our current best guess. The `configure` action prefers an example config from
  the cloned upstream repo as its base, and writes the final file to
  `~/.config/datum_gateway/datum_gateway.json` for easy manual editing.

All runs log to `~/.cache/datum_gateway/install.log` so post-mortems are easy.

## Scope

Non-goals for this folder:

- Installing Bitcoin Knots. Users bring their own.
- Supporting non-Debian distros. RHEL-family would need its own path.
- Installing or running HashGG itself. That's `docker run` / `docker compose up`.
