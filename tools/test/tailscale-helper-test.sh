#!/usr/bin/env bash
# The root helper behind the polkit action tv.subcult.tailscale (ADR 0058,
# ADR 0062), with a stand-in for tailscale. It runs up, down, the sign-in,
# the exit node and a Taildrop send with fixed flags, takes only Tailscale
# addresses and plain file names, refuses everything else without calling
# tailscale, and stops waiting at the sign-in link. The polkit action names
# it and lets the active session run it without a password.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
helper=$root/tools/tailscale/helper.sh
fail() { echo "tailscale-helper-test: $*" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
export TS_TEST="$work" PATH="$work/bin:$PATH"

cat >"$work/bin/tailscale" <<'STUB'
#!/bin/bash
echo "$*" >>"$TS_TEST/calls"
case "$1 ${2:-}" in
"up ")
  case $(cat "$TS_TEST/up-mode" 2>/dev/null) in
  signed-out) printf '\nTo authenticate, visit:\n\n\thttps://login.tailscale.com/a/abc123\n\n' >&2; sleep 30;;
  fails) echo "backend error: boom" >&2; exit 3;;
  esac;;
"file cp") cat >"$TS_TEST/sent";;
esac
exit 0
STUB
chmod +x "$work/bin/tailscale"

calls() { cat "$work/calls" 2>/dev/null || true; }
ok() {
  rm -f "$work/calls"
  "$helper" "$@" </dev/null >/dev/null || fail "refused: $*"
}
refused() {
  rm -f "$work/calls"
  if "$helper" "$@" </dev/null >/dev/null 2>&1; then fail "accepted: $(printf '[%s] ' "$@")"; fi
  [[ -z $(calls) ]] || fail "ran tailscale for $(printf '[%s] ' "$@"): $(calls)"
}

# Fixed command lines.
ok down
[[ $(calls) == down ]] || fail "down: $(calls)"
ok exit-node 100.64.0.2
[[ $(calls) == 'set --exit-node=100.64.0.2 --exit-node-allow-lan-access=true' ]] || fail "exit node: $(calls)"
ok exit-node 100.127.255.254
ok exit-node fd7a:115c:a1e0::3
[[ $(calls) == 'set --exit-node=fd7a:115c:a1e0::3 --exit-node-allow-lan-access=true' ]] || fail "IPv6 exit node: $(calls)"
ok exit-node ''
[[ $(calls) == 'set --exit-node=' ]] || fail "clearing the exit node: $(calls)"

# Anything else is refused before tailscale runs.
refused
refused set --ssh
refused status
refused down --accept-routes
refused up --ssh
refused login --operator=alice
refused exit-node
refused exit-node 100.64.0.2 extra
for addr in 10.0.0.1 100.63.255.1 100.128.0.1 100.64.0.256 100.64.0 '100.64.0.2 --ssh' --ssh '100.64.0.2,' \
  kvant kvant.tail1.ts.net fd7a:115c:a1e1::3 'fd7a:115c:a1e0:::3' 'FD7A:115C:A1E0::3' $'100.64.0.2\n'; do
  refused exit-node "$addr"
  refused send "$addr" notes.txt
done

# Taildrop: standard input goes to `tailscale file cp` under the name.
rm -f "$work/calls"
printf 'payload' | "$helper" send 100.64.0.4 'a file.pdf' >/dev/null || fail "send refused"
[[ $(calls) == 'file cp --update-interval=0 --name=a file.pdf - 100.64.0.4:' ]] || fail "send: $(calls)"
[[ $(<"$work/sent") == payload ]] || fail "send did not pass standard input"
for name in '' . .. ../etc/passwd a/b /etc/shadow $'a\nb' $'a\tb' "$(printf 'x%.0s' {1..256})"; do
  refused send 100.64.0.4 "$name"
done
refused send 100.64.0.4
refused send 100.64.0.4 a.txt extra
ok send 100.64.0.4 "$(printf 'x%.0s' {1..255})"
ok send 100.64.0.4 .hidden

# Sign-in: the link, at once, and tailscale up is not left behind.
echo signed-out >"$work/up-mode"
start=$SECONDS
out=$("$helper" login) || fail "login failed"
[[ $out == https://login.tailscale.com/a/abc123 ]] || fail "login printed: $out"
((SECONDS - start < 10)) || fail "login waited for the browser"
if pgrep -f "$work/bin/tailscale up" >/dev/null; then fail "tailscale up left running"; fi
# up signed out: no link on standard output, a failure that says why.
if out=$("$helper" up 2>"$work/err"); then fail "up succeeded while signed out"; fi
[[ -z $out && $(<"$work/err") == 'Signed out: sign in first' ]] || fail "up signed out: [$out] $(<"$work/err")"
# Signed in: up connects and exits; login does the same with nothing to print.
echo >"$work/up-mode"
out=$("$helper" up) || fail "up failed"
[[ -z $out ]] || fail "up printed: $out"
out=$("$helper" login) || fail "login failed while signed in"
[[ -z $out ]] || fail "login printed while signed in: $out"
# A failure passes tailscale's words and status on.
echo fails >"$work/up-mode"
status=0
"$helper" up 2>"$work/err" >/dev/null || status=$?
[[ $status == 3 ]] || fail "up failure status: $status"
grep -qx 'backend error: boom' "$work/err" || fail "up failure text: $(<"$work/err")"

# The polkit action: this helper, without a password for the active session only.
policy=$root/default/polkit/tv.subcult.tailscale.policy
grep -q '<annotate key="org.freedesktop.policykit.exec.path">/usr/lib/subcult/tailscale-helper</annotate>' "$policy" ||
  fail "the polkit action does not name the helper"
{ grep -q '<allow_active>yes</allow_active>' "$policy" && grep -q '<allow_inactive>auth_admin</allow_inactive>' "$policy" &&
  grep -q '<allow_any>auth_admin</allow_any>' "$policy"; } || fail "polkit defaults"
if command -v xmllint >/dev/null; then xmllint --noout "$policy" || fail "the polkit action is not well-formed"; fi
echo "tailscale-helper-test: ok"
