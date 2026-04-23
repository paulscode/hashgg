<p align="center">
  <img src="logo.png" alt="HashGG" width="200">
</p>

# HashGG

**Sovereign hash routing for StartOS. No port forwarding. No static IP. No middleman.**

HashGG exposes your [Datum Gateway](https://github.com/ocean-xyz/datum-gateway) stratum port to the public internet — so any miner, anywhere, can connect to *your* node and mine blocks *you* built. Choose between two tunnel options:

- **playit.gg** (~$3/month, fiat) — easiest setup, managed service
- **VPS SSH tunnel** (~$11/month, Bitcoin) — privacy-focused, full control, no third-party dependency on the data path

---

## Why "GG"?

"GG" — short for *good game* — is what players say when a match is over. Not as trash talk. As a statement of fact: the outcome is clear, the deciding move already happened, and everyone at the table knows it.

That's the energy here.

Centralized mining pools have been the dominant strategy for over a decade — convenient, default, and seemingly unassailable. But the dominance was never about superiority. It was about friction. Running your own mining infrastructure was hard, and pointing real hashpower at it was harder.

Those barriers are falling. Datum Gateway lets you build your own block templates. OCEAN pays you non-custodially. Braiins Hashpower lets you rent petahashes on demand. The only piece missing was making your stratum port reachable from the outside world without being a network engineer.

HashGG is that piece. And once the friction is gone, the incentives do the rest. When anyone can easily route hashpower through their own node — choosing their own transactions, their own signaling, their own policies — the old centralized model stops being the default. It becomes *optional*. And that's when the game changes.

Not with a bang. Just a quiet recognition that the dominant strategy isn't dominant anymore.

Pool centralization: *gg.*

---

## What It Does

HashGG is a [StartOS](https://start9.com) service that runs alongside Datum Gateway on your Start9 server. It:

1. Manages a tunnel between your Datum Gateway stratum port and the public internet — via either [playit.gg](https://playit.gg) or an SSH reverse tunnel to a VPS you control
2. Supervises the tunnel agent and reconnects automatically
3. Gives you a public `stratum+tcp://` endpoint you can hand to any miner

No router configuration. No dynamic DNS. No VPN. Works behind NAT, double NAT, CGNAT — whatever your ISP throws at you.

### How it works

**playit.gg mode:**
```
Your miners ──→ playit.gg relay ──→ HashGG tunnel ──→ Datum Gateway ──→ OCEAN pool
  (anywhere)      (internet)       (your Start9)     (your Start9)     (non-custodial payout)
```

**VPS SSH tunnel mode:**
```
Your miners ──→ your VPS ──→ SSH reverse tunnel ──→ Datum Gateway ──→ OCEAN pool
  (anywhere)     (public IP)         (your Start9)           (your Start9)     (non-custodial payout)
```

Your Start9 server builds its own block templates using your own Bitcoin node. Datum Gateway serves those templates to miners via the stratum protocol. HashGG punches a hole through your NAT so miners can reach it from anywhere — without touching your router.

## Requirements

HashGG runs two ways — pick the one that matches your setup:

- **On StartOS** (primary): a [Start9](https://start9.com) server running **StartOS 0.3.5.1** or **0.4.0**. Follow [Quick Start (StartOS)](#quick-start-startos) below.
- **On Debian-based Linux** (Debian, Ubuntu, Linux Mint, Zorin, etc.) running Bitcoin Knots directly: jump to [Running HashGG on Linux](#running-hashgg-on-linux-without-startos). *Other distros (RHEL/Fedora/Arch/etc.) can run the HashGG container too, but the Datum Gateway install steps will need local adaptation — the install script is Debian-only.*

Either path, you'll also need:

- **[Datum Gateway](https://github.com/ocean-xyz/datum-gateway)** running alongside Bitcoin Knots.
- One of:
  - A [playit.gg](https://playit.gg) account with **Premium** (~$3/month) — [why?](#why-premium), **or**
  - A VPS with root SSH access (any Debian, Ubuntu, or RHEL-family distro). We recommend [BitLaunch](https://app.bitlaunch.io/signup) (~$11/month, funded with Bitcoin, anonymous signup).

## Quick Start (StartOS)

1. Install **Datum Gateway** on your StartOS server (requires Bitcoin Knots)
2. Install **HashGG** from the StartOS marketplace (or sideload the `.s9pk`)
3. Open the HashGG dashboard and pick your tunnel method:
   - **playit.gg** — approve a one-time claim URL in your browser, then you're done
   - **VPS** — provision a VPS, paste one setup script into its root shell, enter its IP in the HashGG UI
4. Copy your public mining endpoint
5. Point your miners to it

That's it. Your miners can now connect to your Datum Gateway from anywhere on the internet.

---

## Running HashGG on Linux (without StartOS)

If you're running Bitcoin Knots directly on a Linux machine (not a Start9 server) — for example `bitcoin-qt` on a Linux Mint workstation — you can run HashGG in Docker on the same machine. You'll set up Datum Gateway natively and HashGG in a container that talks to it.

### Prerequisites

- **Bitcoin Knots** (as `bitcoin-qt` or `bitcoind`) already installed.
- **A Debian-based distribution** — tested on Linux Mint; should work on Debian, Ubuntu, Zorin, and the rest of the Ubuntu/Debian family. RHEL/Fedora/Arch/openSUSE users can still run the HashGG container, but the `host-setup/install-datum-gateway.sh` script will refuse to run (it's apt/dpkg-based) — you'll need to install Datum Gateway via your own distro's tooling.
- **Docker Engine** + **Docker Compose plugin** (`sudo apt install docker.io docker-compose-v2`, then add yourself to the `docker` group and log out/in).
- **Git and make** (`sudo apt install git make`) to fetch the repo and drive the build.

> **Before you start — wallet note.** Datum Gateway gets full RPC access to whatever Bitcoin Knots node it points at. If that Knots has a loaded wallet with real funds, **a compromise of Datum is a compromise of the wallet**. Either use a dedicated Knots instance with `disablewallet=1` for mining, or confirm no meaningful funds live on this node before continuing.

### Step 1 — Set up Datum Gateway

Clone this repo, then follow the five-step script. Full details in [`host-setup/README.md`](host-setup/README.md).

```bash
git clone https://github.com/paulscode/hashgg.git
cd hashgg
bash host-setup/install-datum-gateway.sh check-knots    # print a paste-in for bitcoin.conf
# (edit bitcoin.conf with the lines it prints, restart bitcoin-qt, re-run check-knots)
bash host-setup/install-datum-gateway.sh build          # build Datum from the pinned release
bash host-setup/install-datum-gateway.sh configure      # set payout address, coinbase tags
bash host-setup/install-datum-gateway.sh open-firewall  # open Docker bridge -> Datum (ufw)
bash host-setup/install-datum-gateway.sh run            # run Datum in this terminal; Ctrl-C stops it
```

Leave that terminal open — Datum keeps running while you mine. (For `bitcoind`-as-a-service users, swap the last line for `install-daemon` and it becomes a systemd service instead.)

### Step 2 — Start HashGG

In a new terminal:

```bash
docker compose up -d
docker compose logs hashgg     # should show backend listening on :3000
```

The web UI binds to `127.0.0.1:3000` by default (the UI has no authentication — see [Security notes](#security-notes) below). If you want LAN access, edit `docker-compose.yml` and put a reverse proxy with auth in front.

### Step 3 — Pick a tunnel and point a miner

Open http://localhost:3000 in your browser. Pick **playit.gg** or **VPS**, follow the UI through the setup flow, copy the resulting public `stratum+tcp://host:port` endpoint, and point any miner at it.

### Security notes

- HashGG's web UI ships with **no authentication**. The default compose binding is loopback-only for that reason. Don't expose port 3000 to the LAN without a reverse proxy + auth in front.
- Datum's admin API is bound to `127.0.0.1:7152` by our config generator — reachable from the host, not from Docker containers or the LAN.
- The Docker bridge → Datum firewall rule uses `172.16.0.0/12` (the full RFC1918 range Docker allocates bridge networks from). Any container on your Docker daemon can therefore reach Datum's stratum port. On a single-user workstation that's fine; on a shared host it's a consideration.
- The VPS SSH private key (VPS mode) and the playit secret (playit mode) are stored in the `hashgg-data` named Docker volume. Back them up like credentials.

---

### Why Premium?

playit.gg's free tier only offers game-specific tunnel types (Minecraft, Terraria, etc.) that inspect traffic at the relay and reject anything that isn't the expected game protocol. Mining stratum traffic gets rejected by these tunnels. Premium unlocks raw TCP tunnels that forward traffic without inspection — exactly what mining needs. At ~$3/month, it's the cheapest way to expose a port through NAT without running your own VPS.

---

## Why This Matters

### Block template sovereignty

When you mine through a centralized pool, the pool decides what goes in your blocks — which transactions to include, which soft forks to signal for, which policies to enforce. You provide the hashpower; they make all the decisions.

Datum Gateway flips this. It lets you build your own block templates with your own Bitcoin node, then submit them to [OCEAN](https://ocean.xyz) for non-custodial payout. You choose the transactions. You choose the signaling. The pool just coordinates the work.

But Datum Gateway has a problem: it listens on a local port. If your Start9 is behind a home router (and it almost certainly is), miners outside your local network can't reach it.

**HashGG solves that.** It tunnels your stratum port to the internet so any miner can connect — whether it's your Bitaxe in the garage, an S21 at a friend's house, or petahashes of rented hashpower from a marketplace.

### Rented hashpower changes the scale

Home miners running a Bitaxe or a few ASICs bring sovereignty but limited hashrate. A top-of-the-line Bitaxe tops out around 2 TH/s. That's real mining, and it matters for decentralization — but it won't move the hashrate distribution chart.

[Braiins Hashpower](https://hashpower.braiins.com/) changes the calculus. It's a real-time hashrate marketplace where anyone can rent SHA-256 mining power — starting at 1 PH/s — and point it at any stratum endpoint. Including yours.

**Any stratum endpoint. Including the one HashGG gives you.**

The gross cost isn't trivial, but mining earns most of it back. You're paying for the *delta* — the net cost after block rewards — which can be single-digit percentages of the gross. The hashrate nearly pays for itself; what you're really buying is *control*.

Here's the pipeline:

1. **Your Bitcoin node** builds block templates with the transactions and signaling you choose
2. **Datum Gateway** serves those templates to miners via the stratum protocol
3. **HashGG** punches the stratum port through to the internet — no router config needed
4. **Braiins Hashpower** delivers PH/s-scale hashrate to your endpoint on demand
5. **OCEAN** coordinates the mining and pays you directly, non-custodially

The result: a sovereign operator at home, commanding petahashes of mining power — all of it building blocks *they* designed, with transactions *they* selected, signaling for the consensus rules *they* support.

### The big picture

Centralized pools have held the dominant position for years because they're convenient and the alternatives weren't practical. HashGG eliminates one of the last friction points — network accessibility — making it trivial to route real hashpower through your own node.

When enough people can easily point hashpower at their own block templates, the game theory that sustains pool centralization starts to unravel. Not all at once. But inevitably.

gg

---

## Status

Beta. All core functionality works — HashGG has been tested end-to-end with real ASIC miners connecting through the tunnel and receiving work from Datum Gateway. The aarch64 (ARM) build exists but has not been tested on ARM hardware.

## License

MIT
