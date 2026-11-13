---
title: "ADR 0058: Tailscale"
type: decision
status: accepted
adr: 58
created: 2026-11-07
updated: 2026-11-13
tags: [decision, adr, system, network]
aliases: [ADR 0058, S12, Tailscale, Taildrop]
---

# ADR 0058: Tailscale

Decision map item S12, added 2026-11-07. Accepted 2026-11-07.

## Decision

- **Tailscale** is preinstalled (`tailscale` from Arch's `extra`, 1.104.2 on
  2026-11-07). `tailscaled` is enabled; the user signs in when they want it.
- A **bar panel** shows status, lets the user switch exit nodes and browse
  machines, and copies addresses, as Omarchy's `omarchy.tailscale` panel does.
- **Taildrop**: files sent to the machine land in `~/Downloads`
  automatically, through a small user service.
- MagicDNS and Tailscale's split DNS stay on Tailscale's own link
  ([[0020-dns|ADR 0020]]).

## Options considered

| Option | Why not chosen |
|---|---|
| Not preinstalled | The owner's fleet uses Tailscale on every machine. |

## Borrowed from Omarchy

The `omarchy.tailscale` shell panel, `omarchy-tailscale-receive.service` and
its receive script (staging directory under Downloads), and the exit-node
pause during captive portal sign-in.

## Consequences

- `tailscaled` runs all the time once enabled; it is idle when not signed in.
  ([[0054-lightweight-battery-first|ADR 0054]] counts it.)
- The Taildrop receiver runs only while signed in.
- Proton VPN is also preinstalled ([[app-list|App list]]). When connected it
  sets its own DNS and can block traffic outside the tunnel, which overrides
  the DNS trust policy ([[0020-dns|ADR 0020]]) and can conflict with a
  Tailscale exit node. At home, the owner's gateway already routes through
  Proton, so connecting the app there tunnels twice. Test both together
  before relying on them.
- Firewall: Tailscale manages its own `tailscale0` interface. Omarchy's
  firewall script has no Tailscale rule; check whether ufw needs one when
  implementing ([[0019-firewall|ADR 0019]]).

## Progress

- 2026-11-13: The bar has a Tailscale widget and panel
  (`shell/widgets/tailscale`): connection state, this machine's name and
  address, the other machines with their addresses (a click copies one),
  on and off, sign-in, the exit node, and sending files with Taildrop
  through the desktop portal's file picker (`subcult tailscale send`). It
  is in the default bar and reads `tailscale status --json` every minute on
  AC and five on battery, and when the panel opens.
- 2026-11-13: Operator rights. tailscaled refuses `up`, `down`, `set` and
  `file get` to a user who is not its operator, and `tailscale set
  --operator` needs the running daemon, which the installer's chroot does
  not have. The installer enables `subcult-tailscale-operator@<user>.service`,
  which runs `tailscale set --operator=<user>` once at first boot; a marker
  in `/var/lib/subcult` keeps a later choice in place. A migration does the
  same on installs from before. A user added later gets an "Allow this
  account" button in the panel (pkexec, an administrator's password). Seen
  with tailscale 1.104.7 in a container: the operator setting survives
  `tailscale logout`, but `tailscale login` run by the operator starts a
  new profile and drops it, so the panel signs in with plain `tailscale up`,
  which keeps it.
- 2026-11-13, after review: the operator can change every tailscaled
  setting without a password, Tailscale SSH (a root SSH server) included,
  which is a way to root that skips the local password. This ADR did not
  decide that; [[0062-privilege-policy|ADR 0062]] now lists the grant, what
  it allows and the narrower alternative, pending the owner's decision.
  tailscaled has one operator: "Allow this account" takes the role from any
  other account (the panel says so), while the boot unit and the migration
  leave another account's role in place. Signed out, `tailscale up` by a
  user who is not the operator may fail with a demand to repeat
  `--operator=<the operator>` instead of "Access denied"; the panel treats
  both as "not the operator". An exit node picked in the panel keeps the
  local network reachable (`--exit-node-allow-lan-access=true`), and the
  panel addresses a machine by its Tailscale address for the exit node and
  for Taildrop.
- 2026-11-13: Taildrop receive. `subcult-tailscale-receive.service` (user,
  every session) runs `subcult tailscale receive`: `tailscale file get
  --wait` into a staging folder under `~/Downloads`, then each file moves to
  a free name and is announced. Signed out, tailscaled answers `file get`
  with "no storage directory" at once, so the receiver tries again every
  five minutes and the panel restarts it when it sees the sign-in. "Runs
  only while signed in" became "sleeps while signed out". `file get` writes
  each file under its final name, so each get uses its own folder, which
  is delivered only after the get succeeds; a folder from a get that was
  cut off is thrown away at the next start, and tailscaled hands its files
  over again.
- Still open: the exit-node pause during captive portal sign-in
  ([[0020-dns|ADR 0020]]) and whether ufw needs a `tailscale0` rule.

Related: [[decision-map|Decision map]] · [[0020-dns|ADR 0020]] · [[0016-networking|ADR 0016]]
