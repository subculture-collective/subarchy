#!/usr/bin/env bash
# Tailscale (ADR 0058): the user is tailscaled's operator, so the bar's
# Tailscale panel can turn it on and off, sign in and pick an exit node,
# and Taildrop can save files, all without sudo. New installs enable
# subcult-tailscale-operator@<user> from the installer; this does the same
# for an install from before and runs it now when tailscaled is running
# (otherwise at the next boot that starts it). Plain sudo, like the other
# migrations; if sudo is refused the migration stays pending.
unit=$(systemd-escape --template=subcult-tailscale-operator@.service "$USER")
need_sudo() { echo "Tailscale operator setting needs sudo: run subcult update migrate again" >&2; exit 1; }
command -v tailscale >/dev/null || exit 0
if ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
  sudo systemctl enable --quiet "$unit" || need_sudo
fi
if systemctl is-active --quiet tailscaled.service; then
  sudo systemctl start "$unit" || need_sudo
fi
