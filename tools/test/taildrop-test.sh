#!/usr/bin/env bash
# `subcult tailscale receive` and `send` (ADR 0058) with stand-ins for
# tailscale, notify-send and the file picker. Receive: files tailscale
# delivers into staging move to the folder under free names (a taken name
# gets -1), each is announced, files left in staging by an earlier run are
# delivered first, and a refusal (signed out) fails --once. Send: the
# picker's files go to `tailscale file cp` with the machine, a closed picker
# sends nothing, and a failed transfer is announced and fails.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
fail() { echo "taildrop-test: $*" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/home/Downloads"
export TD_TEST="$work" PATH="$work/bin:$PATH" HOME="$work/home"
unset XDG_DOWNLOAD_DIR

cat >"$work/bin/tailscale" <<'STUB'
#!/bin/bash
echo "$*" >>"$TD_TEST/tailscale-log"
case "$1 $2" in
"file get")
  [[ -e $TD_TEST/signed-out ]] && { echo "getting WaitingFiles: Taildrop disabled; no storage directory" >&2; exit 1; }
  dest=${*: -1}
  printf 'new' >"$dest/notes.txt"
  printf 'img' >"$dest/photo.png";;
"file cp")
  [[ -e $TD_TEST/cp-fails ]] && { echo "kvant: no matching peer" >&2; exit 1; };;
esac
exit 0
STUB
cat >"$work/bin/notify-send" <<'STUB'
#!/bin/bash
printf '%s\n' "${*: -2:1} | ${*: -1}" >>"$TD_TEST/notes"
STUB
cat >"$work/chooser" <<'STUB'
#!/bin/bash
echo "$*" >>"$TD_TEST/chooser-log"
[[ -e $TD_TEST/chooser-closed ]] && exit 1
printf '%s\n' "$TD_TEST/a file.pdf" "$TD_TEST/b.txt"
STUB
chmod +x "$work/bin/tailscale" "$work/bin/notify-send" "$work/chooser"

receive() { "$root/bin/subcult-tailscale-receive" --once "$@"; }
dl=$work/home/Downloads

# A taken name is kept, the new file gets -1; a file left in staging by an
# earlier run arrives too.
printf 'old' >"$dl/notes.txt"
mkdir -p "$dl/.taildrop"
printf 'left' >"$dl/.taildrop/left.bin"
receive || fail "receive --once failed"
[[ $(<"$dl/notes.txt") == old && $(<"$dl/notes-1.txt") == new ]] || fail "a taken name was overwritten: $(ls -A "$dl")"
[[ -f $dl/photo.png && -f $dl/left.bin ]] || fail "files missing from Downloads: $(ls -A "$dl")"
[[ -z $(ls -A "$dl/.taildrop") ]] || fail "staging not emptied: $(ls -A "$dl/.taildrop")"
grep -qx 'file get --wait --conflict=rename '"$dl/.taildrop" "$work/tailscale-log" || fail "tailscale file get: $(cat "$work/tailscale-log")"
[[ $(grep -c '^Received ' "$work/notes") == 3 ]] || fail "not every file announced: $(cat "$work/notes")"
grep -qx 'Received notes-1.txt | Saved to ~/Downloads' "$work/notes" || fail "announcement: $(cat "$work/notes")"

# Signed out: --once fails, nothing lands.
touch "$work/signed-out"
if receive 2>/dev/null; then fail "receive --once succeeded while signed out"; fi
rm "$work/signed-out"

# Another folder, given as the argument.
mkdir "$work/elsewhere"
receive "$work/elsewhere" || fail "receive into another folder failed"
[[ -f $work/elsewhere/notes.txt ]] || fail "the folder argument was ignored"

# Send through the picker.
export SUBCULT_FILE_CHOOSER=$work/chooser
: >"$work/notes"
"$root/bin/subcult-tailscale-send" kvant.tail1.ts.net || fail "send failed"
grep -qx "file cp --update-interval=0 -- $work/a file.pdf $work/b.txt kvant.tail1.ts.net:" "$work/tailscale-log" ||
  fail "tailscale file cp: $(tail -1 "$work/tailscale-log")"
grep -qx -- '--title Send to kvant --multiple' "$work/chooser-log" || fail "picker title: $(cat "$work/chooser-log")"
grep -qx 'Sent to kvant | 2 files' "$work/notes" || fail "send announcement: $(cat "$work/notes")"

# A closed picker sends nothing and is no error.
touch "$work/chooser-closed"
n=$(wc -l <"$work/tailscale-log")
"$root/bin/subcult-tailscale-send" kvant || fail "a closed picker failed"
[[ $(wc -l <"$work/tailscale-log") == "$n" ]] || fail "a closed picker still sent"

# Files on the command line, and a failed transfer.
touch "$work/cp-fails"
if "$root/bin/subcult-tailscale-send" 100.64.0.2 "$work/x.txt" 2>/dev/null; then fail "a failed transfer succeeded"; fi
grep -qx 'Nothing sent to 100.64.0.2 | kvant: no matching peer' "$work/notes" || fail "failure announcement: $(cat "$work/notes")"
echo "taildrop-test: ok"
