#!/usr/bin/env bash
# Probe a unit's local API with curl. Reads run by default; writes only with --write.
# Usage: scripts/spike.sh <host> [--write]
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <host> [--write]" >&2
  exit 1
fi
HOST="$1"
BASE="http://$HOST"

get() { echo "GET $1"; curl -sS -m 5 "$BASE$1"; echo; echo; }
post() {
  echo "POST $1 $2"
  curl -sS -m 5 -i -X POST -H 'Content-Type: application/json' -d "$2" "$BASE$1" | head -20
  echo; sleep 1
  get /getState
}

get /info
get /getState

if [[ "${2:-}" != "--write" ]]; then
  echo "Read-only run. Pass --write to try commands (changes the unit's settings)."
  exit 0
fi

# What does a POST return: empty 200 or JSON?
post /setSpeed '{"speed":30,"fanType":"bounded"}'
post /setSpeed '{"speed":10,"fanType":"bounded"}'

# Separate fans while unlinked
post /setSwitch '{"switchType":"bound","value":false}'
post /setSpeed '{"speed":20,"fanType":"supply"}'
post /setSpeed '{"speed":10,"fanType":"supply"}'

# Boost on/off: what speed does getState report during boost?
post /setSwitch '{"switchType":"boost","value":true}'
post /setSwitch '{"switchType":"boost","value":false}'

# Auto: does setSpeed still work, or does it leave auto?
post /setSwitch '{"switchType":"auto","value":true}'
post /setSpeed '{"speed":20,"fanType":"bounded"}'
post /setSwitch '{"switchType":"auto","value":false}'

# Power off/on via bounded
post /setSpeedIsOn '{"value":false,"fanType":"bounded"}'
post /setSpeedIsOn '{"value":true,"fanType":"bounded"}'
