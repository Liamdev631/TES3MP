#!/usr/bin/env bash
# Flip a Kingdom feature flag, safely.
#
#   bash kingdom/tools/kos-flags.sh list
#   bash kingdom/tools/kos-flags.sh get exp_console
#   bash kingdom/tools/kos-flags.sh set exp_console on
#   bash kingdom/tools/kos-flags.sh experiments on      # master switch for all experiments
#
# The flag names come from the server's own known list (kingdom/server-lua/kingdom_flags.lua), so a
# typo is refused here instead of silently doing nothing. The game re-reads this file on every event,
# so a flip takes effect immediately — no restart, no reconnect.

set -euo pipefail

FLAGS_FILE="${KOS_FLAGS_FILE:-/home/liamb/kos-world/flags.json}"
KNOWN_LUA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/server-lua/kingdom_flags.lua"

die() { echo "error: $*" >&2; exit 1; }

known_flags() {
  # the `name = "description"` lines inside Flags.known
  grep -oE '^\s{4}[a-z_]+ = "' "${KNOWN_LUA}" | sed 's/[[:space:]]//g; s/=.*//' | sort -u
}

describe() {
  grep -oE "^\s{4}${1} = \"[^\"]*\"" "${KNOWN_LUA}" | sed 's/.*= "//; s/"$//'
}

require_known() {
  known_flags | grep -qx "$1" || die "'$1' is not a flag this world knows (see: kos-flags.sh list)"
}

flag_state() {
  python3 - "$FLAGS_FILE" "$1" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except FileNotFoundError:
    print("off"); raise SystemExit
except json.JSONDecodeError:
    sys.stderr.write(f"error: {path} is not valid JSON\n"); raise SystemExit(2)
print("on" if data.get(name) is True else "off")
PY
}

write_flag() {
  python3 - "$FLAGS_FILE" "$1" "$2" <<'PY'
import json, os, sys, tempfile
path, name, value = sys.argv[1], sys.argv[2], sys.argv[3] == "on"
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except FileNotFoundError:
    data = {}
data[name] = value
os.makedirs(os.path.dirname(path), exist_ok=True)
handle = tempfile.NamedTemporaryFile("w", dir=os.path.dirname(path), delete=False, encoding="utf-8")
try:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
finally:
    handle.close()
os.replace(handle.name, path)
PY
}

case "${1:-list}" in
  list)
    echo "flags: ${FLAGS_FILE}"
    if [[ -f "${FLAGS_FILE}" ]]; then echo "(file present)"; else echo "(no file yet — every flag is off)"; fi
    echo
    while read -r name; do
      printf '  %-24s %-4s %s\n' "${name}" "$(flag_state "${name}")" "$(describe "${name}")"
    done < <(known_flags)
    echo
    echo "experiments stay off unless the master switch is on as well."
    ;;
  get)
    [[ $# -ge 2 ]] || die "usage: kos-flags.sh get <flag>"
    require_known "$2"
    flag_state "$2"
    ;;
  set)
    [[ $# -ge 3 ]] || die "usage: kos-flags.sh set <flag> on|off"
    require_known "$2"
    case "$3" in
      on|off) ;;
      *) die "value must be 'on' or 'off'" ;;
    esac
    write_flag "$2" "$3"
    printf '%s is now %s\n' "$2" "$(flag_state "$2")"
    if [[ "$2" != experiments" && "$2" == exp_* && "$(flag_state experiments)" == off ]]; then
      echo "note: experiments master switch is off, so this has no effect yet."
      echo "      bash kingdom/tools/kos-flags.sh set experiments on"
    fi
    ;;
  *)
    die "unknown command '$1' — try: list, get, set"
    ;;
esac
