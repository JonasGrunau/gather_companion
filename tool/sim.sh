#!/usr/bin/env bash
# Run the app on an iOS simulator through the mock harness.
#
# The real entrypoint (lib/main.dart) dead-ends at the pairing screen on a sim — no
# camera to scan a bridge, no Gather socket behind it. lib/main_harness.dart injects a
# FakeCollector + ScriptedCall and lands in the walkable Office with no wire, which is
# the only way to actually watch the app move on a bare sim. This wraps the long
# invocation so a sim run is one command.
#
# Usage:
#   tool/sim.sh                 # office scenario, auto-picks a booted sim
#   tool/sim.sh --gameboy       # boot straight into the Gameboy handheld
#   tool/sim.sh -s party        # a different AppScenario (default: office)
#   tool/sim.sh -p 6            # seat 6 of the cast (default: 4)
#   tool/sim.sh -d <udid>       # target a specific simulator
#   tool/sim.sh --gameboy -- -v # everything after `--` is passed to `flutter run`
#
# Flags stack. Anything after a bare `--` is forwarded verbatim to `flutter run`.
set -euo pipefail

scenario="office"
participants="4"
device=""
gameboy="false"
gameboy_passed="false"
passthrough=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gameboy)        gameboy="true";  gameboy_passed="true"; shift ;;
    --no-gameboy)     gameboy="false"; gameboy_passed="true"; shift ;;
    -s|--scenario)    scenario="$2"; shift 2 ;;
    -p|--participants) participants="$2"; shift 2 ;;
    -d|--device)      device="$2"; shift 2 ;;
    --)               shift; passthrough=("$@"); break ;;
    -h|--help)        sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "sim.sh: unknown argument '$1' (use -- to pass flags to flutter run)" >&2; exit 2 ;;
  esac
done

# A booted simulator if one is up, otherwise the first available iOS simulator. Leaves
# the choice to `flutter run` when neither is found, so its own error is what shows.
if [[ -z "$device" ]]; then
  device="$(xcrun simctl list devices booted -j 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];print(next((v["udid"] for devs in d.values() for v in devs if v.get("state")=="Booted"),""))' 2>/dev/null || true)"
fi

args=(flutter run -t lib/main_harness.dart
  --dart-define=TARGET=app
  --dart-define=SCENARIO="$scenario"
  --dart-define=PARTICIPANTS="$participants")

[[ -n "$device" ]] && args+=(-d "$device")
# Only pass GAMEBOY when the user said so, so a plain run leaves the sim's sticky
# preference alone rather than silently clearing it.
[[ "$gameboy_passed" == "true" ]] && args+=(--dart-define=GAMEBOY="$gameboy")
[[ ${#passthrough[@]} -gt 0 ]] && args+=("${passthrough[@]}")

echo "> ${args[*]}"
exec "${args[@]}"
