#!/bin/sh
# Measures the app on a long chat, against the pretend gateway's "long" mode: CPU while idle
# with the chat open, CPU per sidebar toggle (⌘B), and CPU while a long reply streams.
#
#   Tools/bench-chat.sh [path to a HermesBot binary]   # default: App/.build/release/HermesBot
#
# Build it first with `swift build -c release` in App: a debug build is not representative.
# It types into the app it starts (by its pid), so the terminal running this needs the
# Accessibility permission. Port 9149; it stops both processes it started when it ends.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
app=${1:-$here/App/.build/release/HermesBot}
port=9149

python3 "$here/Tools/fake-gateway.py" $port long >/dev/null 2>&1 &
gateway=$!
HERMES_URL=127.0.0.1:$port HERMES_TOKEN=demo "$app" >/dev/null 2>&1 &
pid=$!
trap 'kill $pid $gateway 2>/dev/null || true' EXIT INT TERM

# CPU seconds the app has used so far.
cpu() { ps -o cputime= -p $pid | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'; }
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null; sleep 0.5; }
# Each key goes to this app's process, brought to the front first: something else may have
# come forward meanwhile.
keys() { osascript -e "tell application \"System Events\"" -e "set frontmost of (first process whose unix id is $pid) to true" -e "delay 0.1" -e "$1" -e "end tell" >/dev/null; }
rate() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { printf "%.1f", (b - a) / t * 100 }'; }

sleep 8   # connects, reads the roster and the main bot's chat
front
sleep 4

a=$(cpu); sleep 20; b=$(cpu)
echo "idle, in front:        $(rate $a $b 20)% CPU"

a=$(cpu)
for _ in 1 2 3 4 5 6 7 8 9 10; do keys 'keystroke "b" using command down'; sleep 1.5; done
b=$(cpu)
echo "sidebar toggle (⌘B):   $(awk -v a=$a -v b=$b 'BEGIN { printf "%.3f", (b - a) / 10 }') CPU s each (10 toggles, 1.5 s apart)"

a=$(cpu); start=$(date +%s)
# "long", by key codes: typed text did not always arrive. ⌘I puts the caret in the message box.
keys 'keystroke "i" using command down'
for code in 37 31 45 5; do keys "key code $code"; done
keys 'key code 36'
sleep 20   # 1.2 s and 1.2 s of tool, then about 13 s of words, then the stored chat read again
b=$(cpu)
echo "long reply streaming:  $(rate $a $b 20)% CPU over 20 s ($(awk -v a=$a -v b=$b 'BEGIN { printf "%.2f", b - a }') CPU s)"

a=$(cpu); sleep 20; b=$(cpu)
echo "idle after:            $(rate $a $b 20)% CPU"
