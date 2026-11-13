#!/usr/bin/env bash
# Installed as /usr/lib/subcult/tailscale-operator; run as root by
# subcult-tailscale-operator@<user>.service (ADR 0058, ADR 0062). Makes the
# user tailscaled's operator, unless another account already is: tailscaled
# has one operator, and taking the role from someone else is for that
# person's "Allow this account" button, not for a boot unit or a migration.
set -euo pipefail

user=${1:?usage: tailscale-operator <user>}
current=$(tailscale debug prefs | sed -n 's/^[[:space:]]*"OperatorUser": "\(.*\)",\{0,1\}$/\1/p')
if [[ -n $current && $current != "$user" ]]; then
  echo "$current already controls Tailscale; $user is left out"
  exit 0
fi
exec tailscale set --operator="$user"
