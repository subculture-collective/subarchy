#!/usr/bin/env bash
# `subcult capture screenshot`, `capture recording` and the region picker
# behind them, with stand-ins for hyprctl, slurp, grim, wl-copy,
# notify-send, satty, gpu-screen-recorder, quickshell, pgrep and pkill.
#
# Screenshot: a dragged region is taken as is; a click takes the window
# under it, or the display outside any window; window and output pick a
# window or take the focused display at its logical size (scaled, turned);
# the PNG lands in Pictures, or the folder user-dirs.dirs names, and on the
# clipboard; the notification's click opens satty on the file; a cancelled
# pick takes nothing.
#
# Recording: a whole display records by name, a region by geometry, with
# both audio sources on --audio; the MP4 lands in Videos; the shell's screen
# mark goes on and off again; a running recorder is stopped with SIGINT.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
fail() { echo "capture-test: $*" >&2; exit 1; }
command -v jq >/dev/null || { echo "capture-test: jq not installed, skipped"; exit 0; }
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/home"
export CT="$work" PATH="$work/bin:$root/bin:$PATH" HOME="$work/home" XDG_RUNTIME_DIR="$work"
unset XDG_CONFIG_HOME XDG_PICTURES_DIR XDG_VIDEOS_DIR

# One 2880x1800 panel at scale 2 (1440x900 logical) with two windows on
# workspace 1, and a window on another workspace.
cat >"$work/bin/hyprctl" <<'STUB'
#!/bin/bash
case $1 in
monitors) cat "$CT/monitors.json" ;;
clients) cat <<'JSON'
[{"at":[100,50],"size":[600,400],"workspace":{"id":1},"hidden":false},
 {"at":[800,50],"size":[500,700],"workspace":{"id":1},"hidden":false},
 {"at":[0,0],"size":[1440,900],"workspace":{"id":2},"hidden":false}]
JSON
;;
esac
STUB
monitors() { # transform
  printf '[{"name":"eDP-1","x":0,"y":0,"width":2880,"height":1800,"scale":2,"transform":%s,"focused":true,"activeWorkspace":{"id":1}}]\n' "$1" >"$work/monitors.json"
}
monitors 0
cat >"$work/bin/slurp" <<'STUB'
#!/bin/bash
echo "$*" >"$CT/slurp-args"
cat >"$CT/slurp-rects"
cat "$CT/slurp-out" 2>/dev/null
STUB
cat >"$work/bin/grim" <<'STUB'
#!/bin/bash
echo "$2" >"$CT/grim-geometry"
printf 'png' >"$3"
STUB
cat >"$work/bin/wl-copy" <<'STUB'
#!/bin/bash
echo "$* $(cat)" >"$CT/clipboard"
STUB
cat >"$work/bin/notify-send" <<'STUB'
#!/bin/bash
echo "$*" >>"$CT/notes"
[[ " $* " == *" -A "* && -e $CT/click ]] && echo default
exit 0
STUB
cat >"$work/bin/satty" <<'STUB'
#!/bin/bash
echo "$*" >"$CT/satty"
STUB
cat >"$work/bin/xdg-open" <<'STUB'
#!/bin/bash
echo "$*" >"$CT/opened"
STUB
# The recorder writes its file and exits, as after a stop.
cat >"$work/bin/gpu-screen-recorder" <<'STUB'
#!/bin/bash
echo "$*" >"$CT/gsr-args"
while (($#)); do [[ $1 == -o ]] && printf 'mp4' >"$2"; shift; done
STUB
cat >"$work/bin/quickshell" <<'STUB'
#!/bin/bash
echo "$*" >>"$CT/ipc"
STUB
# A recorder runs while $CT/running exists; no slurp is open.
cat >"$work/bin/pgrep" <<'STUB'
#!/bin/bash
[[ -e $CT/running ]]
STUB
cat >"$work/bin/pkill" <<'STUB'
#!/bin/bash
echo "$*" >>"$CT/pkill"
[[ $1 == -INT ]] && rm -f "$CT/running"
[[ $1 != -x ]]
STUB
chmod +x "$work/bin/"*

# Waits up to 5 s for a file the background part writes.
await() { for _ in {1..50}; do [[ -s $1 ]] && return 0; sleep 0.1; done; fail "$2"; }

shot() { # slurp-output mode...
  rm -f "$work/grim-geometry" "$work/clipboard" "$work/satty" "$work/notes"
  printf '%s' "$1" >"$work/slurp-out"
  shift
  subcult-capture-screenshot "$@"
}
expect_geometry() { # want what
  [[ $(<"$work/grim-geometry") == "$1" ]] || fail "$2: grim took '$(<"$work/grim-geometry")', want '$1'"
}

# A dragged region; the picker offers the display and the workspace's windows.
file=$(shot '10,20 300x200')
expect_geometry '10,20 300x200' "a dragged region"
[[ $(<"$work/slurp-rects") == $'0,0 1440x900\n100,50 600x400\n800,50 500x700' ]] ||
  fail "picker rectangles: $(<"$work/slurp-rects")"
[[ $file == "$HOME/Pictures/screenshot-"*.png && -f $file ]] || fail "saved as '$file'"
[[ $(<"$work/clipboard") == "--type image/png png" ]] || fail "clipboard: $(<"$work/clipboard")"
await "$work/notes" "no notification"

# A click takes the window under it, or the display outside the windows.
shot '850,600 1x1' >/dev/null
expect_geometry '800,50 500x700' "a click on a window"
shot '50,800 0x0' >/dev/null
expect_geometry '0,0 1440x900' "a click beside the windows"

# window: slurp picks among the windows only.
shot '100,50 600x400' window >/dev/null
[[ $(<"$work/slurp-args") == -r && $(<"$work/slurp-rects") == $'100,50 600x400\n800,50 500x700' ]] ||
  fail "window picker: $(<"$work/slurp-args") / $(<"$work/slurp-rects")"
expect_geometry '100,50 600x400' "a window"

# output: the focused display at its logical size, turned when portrait.
shot '' output >/dev/null
expect_geometry '0,0 1440x900' "the display"
monitors 1
shot '' output >/dev/null
expect_geometry '0,0 900x1440' "a portrait display"
monitors 0

# A cancelled pick takes nothing.
if [[ -n $(shot '') ]]; then fail "a cancelled pick printed a file"; fi
[[ ! -e $work/grim-geometry ]] || fail "a cancelled pick took a screenshot"

# user-dirs.dirs moves the folder; a click on the notification opens satty.
mkdir -p "$HOME/.config"
# shellcheck disable=SC2016 # user-dirs.dirs is written with a literal $HOME
echo 'XDG_PICTURES_DIR="$HOME/Shots"' >"$HOME/.config/user-dirs.dirs"
touch "$work/click"
file=$(shot '10,20 300x200')
[[ $file == "$HOME/Shots/screenshot-"*.png ]] || fail "user-dirs.dirs ignored: '$file'"
await "$work/satty" "the notification's click opened nothing"
[[ $(<"$work/satty") == "--filename $file --output-filename $file --actions-on-enter save-to-clipboard --save-after-copy --copy-command wl-copy" ]] ||
  fail "satty: $(<"$work/satty")"
rm "$work/click" "$HOME/.config/user-dirs.dirs"

record() { # slurp-output args...
  rm -f "$work/gsr-args" "$work/ipc" "$work/notes"
  printf '%s' "$1" >"$work/slurp-out"
  shift
  subcult-capture-recording "$@"
  await "$work/notes" "no notification after the recording"
}

# A click on the display records it by name; the mark goes on and off.
record '50,800 1x1'
[[ $(<"$work/gsr-args") == "-w eDP-1 -k auto -f 60 -fm cfr -fallback-cpu-encoding yes -o $HOME/Videos/screenrecording-"*.mp4 ]] ||
  fail "display recording: $(<"$work/gsr-args")"
grep -q 'Screen recording saved' "$work/notes" || fail "recording note: $(<"$work/notes")"
ipc='-p /usr/share/subcult/shell call subcult.screencasts setRecording'
await "$work/ipc" "the screen mark was not set"
grep -qx "ipc $ipc true" "$work/ipc" || fail "the screen mark was not set: $(<"$work/ipc")"
[[ $(tail -n1 "$work/ipc") == "ipc $ipc false" ]] || fail "the screen mark was left on: $(<"$work/ipc")"

# A region by geometry, with the desktop and the microphone.
record '10,20 300x200' --audio
[[ $(<"$work/gsr-args") == "-w region -region 300x200+10+20 "*" -a default_output|default_input -ac aac" ]] ||
  fail "region recording: $(<"$work/gsr-args")"

# A running recorder is stopped with SIGINT, and nothing new starts.
: >"$work/pkill"
rm -f "$work/gsr-args"
touch "$work/running"
subcult-capture-recording
[[ $(<"$work/pkill") == "-INT -f ^gpu-screen-recorder" ]] || fail "stop: $(<"$work/pkill")"
[[ ! -e $work/gsr-args ]] || fail "a stop started a recording"

if subcult-capture-recording --bogus 2>/dev/null; then fail "an unknown option was accepted"; fi
echo "capture-test: ok"
