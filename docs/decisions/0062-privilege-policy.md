---
title: "ADR 0062: sudo and polkit policy"
type: decision
status: accepted
adr: 62
created: 2026-11-07
updated: 2026-11-13
tags: [decision, adr, security]
aliases: [ADR 0062, sudo, polkit]
---

# ADR 0062: sudo and polkit policy

Accepted 2026-11-07.

## Decision

- `sudo` and polkit ask for the password by default (fingerprint or FIDO2
  where enrolled; [[0023-authentication|ADR 0023]]).
- **Some actions skip the prompt** through narrow sudoers rules and polkit
  rules that name exact commands, never a wildcard:
  - the system update command and its steps (`subcult update`);
  - setting the time zone (`tzupdate`, as Omarchy does);
  - reboot, shutdown, suspend and hibernate (already allowed for the active
    session by logind);
  - mounting removable drives (udisks), network changes (NetworkManager) and
    power profiles (already allowed for the active session).
- **"Skip sudo for X minutes"** in the menu and launcher: pick 5, 15, 30 or 60
  minutes, confirm with the password once, and `sudo` stops asking for that
  long. Implemented as a sudoers drop-in with a per-user timestamp timeout,
  removed by a systemd timer when the time runs out, on lock, and on logout.
  The bar shows a countdown while it is active.

The owner asked for "some actions" to skip the prompt and left the starting
list to the agent (2026-11-07); the list above is that starting list.

## Actions added since

- `tv.subcult.theme.system-apply` (issue #103): the privileged half of
  `subcult theme apply-system`, through pkexec; the action names the exact
  program (`/usr/bin/subcult-theme`), which takes only colours as arguments.
  It asks for an administrator's password (`auth_admin_keep`), as the
  default above says; it is not on the password-free list.
- `tv.subcult.docker.tui` (2026-11-13, [[0055-containers|ADR 0055]]):
  lazydocker as root through pkexec while the user is not in the `docker`
  group; the action names `/usr/lib/subcult/lazydocker-root`, which takes
  only the terminal type. `auth_admin_keep`, not password-free: driving
  Docker is root access.
- Tailscale operator (2026-11-13, [[0058-tailscale|ADR 0058]]): the
  installed user is tailscaled's operator, set at first boot by
  `subcult-tailscale-operator@<user>.service` and on older installs by a
  migration (one sudo prompt during `subcult update`). A user added later
  gets an "Allow this account" button in the bar's Tailscale panel, which
  runs `pkexec tailscale set --operator=$USER` under polkit's generic
  `org.freedesktop.policykit.exec` action (an administrator's password).
  The panel needs this for on/off, sign-in and the exit node, and the
  Taildrop receiver for `tailscale file get`. **It grants more than that.**
  The operator can change every tailscaled setting without a password,
  including turning on Tailscale SSH (`tailscale set --ssh`), advertising
  routes or an exit node, and `tailscale serve`; checked with tailscale
  1.104.7 in a container. Tailscale SSH runs as root and admits whoever
  the tailnet's SSH policy allows. Tailscale's default policy lets the
  owner's own devices in as root after a browser check, so any program
  running as the user can reach root that way without the local password.
  Tailscale 1.104 has no system policy that turns Tailscale SSH off
  (`/etc/tailscale/syspolicy.json` rejects such a key). tailscaled has one
  operator: allowing a second account takes the role from the first; the
  boot unit and the migration leave another account's role in place. The
  narrower alternative, not built: a root helper under a polkit action that
  runs only `tailscale up`, `down` and `set --exit-node=<address>`, plus a
  system-side Taildrop receiver. **Owner decision pending** (PR #157).

## Borrowed from Omarchy

`omarchy sudo passwordless` (permanent toggle) and `omarchy-sudo-keepalive`,
and Omarchy's sudoers rule for `tzupdate`. Subarchy's timed version replaces
the permanent toggle.

## Consequences

- During a skip window any process the user runs can use `sudo`; the
  countdown makes that visible.
- Each passwordless rule is reviewed when the command it names changes.

## Progress

- 2026-11-07: `subcult update` needs no password for its root steps. They
  are `subcult-update privileged snapshot|upgrade [--noconfirm]|prune`,
  each running a fixed command, and `/etc/sudoers.d/50-subarchy-update`
  allows exactly those four command lines for `wheel`. Removing orphaned
  packages still asks. The VM test runs the update after `sudo -k` with no
  input. The other rules (time zone, the "skip sudo for X minutes" menu) are
  still to do.

Related: [[decision-map|Decision map]] · [[0023-authentication|ADR 0023]] · [[0063-security-hardening|ADR 0063]]
