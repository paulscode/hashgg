<p align="center">
  <img src="logo.png" alt="HashGG" width="200">
</p>

# HashGG

**Sovereign hash routing for StartOS. No port forwarding. No static IP. No middleman.**

HashGG exposes your [Datum Gateway](https://github.com/ocean-xyz/datum-gateway) stratum port to the public internet through a [playit.gg](https://playit.gg) tunnel — so any miner, anywhere, can connect to *your* node and mine blocks *you* built.

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

1. Manages a [playit.gg](https://playit.gg) tunnel agent — setup, supervision, automatic reconnection
2. Bridges traffic from the public internet to your Datum Gateway stratum port
3. Gives you a public `stratum+tcp://` endpoint you can hand to any miner

No router configuration. No dynamic DNS. No VPN. Works behind NAT, double NAT, CGNAT — whatever your ISP throws at you.

### How it works

```
Your miners ──→ playit.gg relay ──→ HashGG tunnel ──→ Datum Gateway ──→ OCEAN pool
  (anywhere)      (internet)       (your Start9)     (your Start9)     (non-custodial payout)
```

Your Start9 server builds its own block templates using your own Bitcoin node. Datum Gateway serves those templates to miners via the stratum protocol. HashGG punches a hole through your NAT so miners can reach it from anywhere — without touching your router.

## Requirements

- A [Start9](https://start9.com) server running **StartOS 0.3.5.1** or **0.4.0**
- **[Datum Gateway](https://github.com/ocean-xyz/datum-gateway)** installed and running (this requires Bitcoin Knots)
- A [playit.gg](https://playit.gg) account with **Premium** (~$3/month) — [why?](#why-premium)

## Quick Start

1. Install **Datum Gateway** on your StartOS server (requires Bitcoin Knots)
2. Sign up at [playit.gg](https://playit.gg) and upgrade to **Premium** (~$3/month)
3. Install **HashGG** from the StartOS marketplace (or sideload the `.s9pk`)
4. Open the HashGG dashboard and complete the one-time setup — you'll approve a connection to your playit.gg account
5. Copy your public mining endpoint
6. Point your miners to it

That's it. Your miners can now connect to your Datum Gateway from anywhere on the internet.

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
