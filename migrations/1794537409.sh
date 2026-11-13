#!/usr/bin/env bash
# Failed passwords (ADR 0063): Subarchy locks an account after 10 failures
# for 2 minutes. Before, Arch's defaults applied (3 failures, 10 minutes),
# and three typos at the greeter or the lock screen locked the account.
# New installs get the file from the installer; this copies it for an
# install from before. A faillock.conf with its own deny or unlock_time
# line is left alone. `subcult update` keeps sudo's timestamp fresh.
conf=/etc/security/faillock.conf
ours=/usr/share/subcult/default/security/faillock.conf
[[ -r $ours ]] || exit 0
if grep -Eq '^[[:space:]]*(deny|unlock_time)[[:space:]]*=' "$conf" 2>/dev/null; then
  exit 0
fi
sudo -n install -m 0644 "$ours" "$conf" ||
  { echo "faillock settings need sudo: run subcult update again" >&2; exit 1; }
