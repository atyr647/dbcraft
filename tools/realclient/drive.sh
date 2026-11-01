#!/usr/bin/env bash
# Drive the real client under Xvfb with synthetic keyboard and mouse input (XTEST via xdotool).
# usage: tools/realclient/drive.sh key KEY [KEY...]        tap keys (xdotool names: F3, space, Escape, e, 1..9, Return ...)
#        tools/realclient/drive.sh hold KEY SECONDS         hold a key (w a s d space shift ...)
#        tools/realclient/drive.sh click left|right [N]     click the mouse button (left breaks, right places/uses)
#        tools/realclient/drive.sh holdclick left SECONDS   hold a mouse button (breaking a block in survival, dragging)
#        tools/realclient/drive.sh look DX DY               turn the camera by relative mouse motion (pixels)
#        tools/realclient/drive.sh chat "text"              open chat (t), type the text, send it (Enter); text may start with / for a command
#        tools/realclient/drive.sh focus [TITLE_REGEX]      focus the game window (the newest matching window by default)
# env: DISPLAY_NUM=99
set -euo pipefail
export DISPLAY=:${DISPLAY_NUM:-99}
win() { xdotool search --name "${1:-Minecraft 26.3}" | tail -1; }
case "${1:-}" in
  focus) xdotool windowfocus "$(win "${2:-}")" ;;
  key) shift; for k in "$@"; do xdotool key --delay 80 "$k"; sleep 0.25; done ;;
  hold) xdotool keydown "$2"; sleep "$3"; xdotool keyup "$2" ;;
  click) b=1; [ "$2" = right ] && b=3; for i in $(seq 1 "${3:-1}"); do xdotool click "$b"; sleep 0.3; done ;;
  holdclick) b=1; [ "$2" = right ] && b=3; xdotool mousedown "$b"; sleep "$3"; xdotool mouseup "$b" ;;
  look)  # the pointer is not grabbed under Xvfb: it stops at the screen edge, and one big jump is ignored.  Small relative steps work (0.15 degree per pixel);
         # absolute warps do not turn the camera, so the pointer is re-centred between batches of at most 300 pixels.
    dx=$2; dy=$3
    while [ "$dx" -ne 0 ] || [ "$dy" -ne 0 ]; do
      xdotool mousemove 427 240; sleep 0.1
      bx=$dx; [ "$bx" -gt 300 ] && bx=300; [ "$bx" -lt -300 ] && bx=-300
      by=$dy; [ "$by" -gt 150 ] && by=150; [ "$by" -lt -150 ] && by=-150
      n=$(( (${bx#-} > ${by#-} ? ${bx#-} : ${by#-}) / 8 + 1 )); sx=$((bx / n)); sy=$((by / n))
      for i in $(seq 1 "$n"); do xdotool mousemove_relative -- "$sx" "$sy"; sleep 0.04; done
      dx=$((dx - sx * n)); dy=$((dy - sy * n))
    done ;;
  chat) xdotool key t; sleep 0.6; xdotool type --delay 60 -- "$2"; sleep 0.3; xdotool key Return ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
