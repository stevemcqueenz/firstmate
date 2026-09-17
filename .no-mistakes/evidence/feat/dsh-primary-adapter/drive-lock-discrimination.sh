#!/usr/bin/env bash
# Adversarial live drive for contract 9: a lock held by a LIVE process that is
# node but NOT dsh-shaped must be treated as stale, so a real DSH session takes
# it. Same session environment as the guard's lock_session. Run from the worktree
# with dsh on PATH; writes nothing outside a throwaway FM_HOME, a throwaway DSH
# profile (removed on exit) and DSH's own session log.
set -u
ROOT=$(pwd -P)
EV=${EV:?}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-dsh-disc.XXXXXX")
PROFILE=fmdshtestdisc
PROFILE_DIR="$HOME/.dsh/profiles/$PROFILE"
cleanup() { [ -n "${HOLDER:-}" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$PROFILE_DIR" "$TMP"; }
trap cleanup EXIT

DSH_REAL=$(node -e 'console.log(require("node:fs").realpathSync(process.argv[1]))' "$(command -v dsh)")
BASE_VERSION=$(node -p "require(process.argv[1] + '/dsh-base/package.json').version" "$(dirname "$(dirname "$(dirname "$DSH_REAL")")")")

HOME_DIR="$TMP/home"; WORK="$TMP/disc-work"
mkdir -p "$HOME_DIR/state" "$WORK"

# Alive, comm=node, argv WITHOUT any dsh launcher shape.
node -e 'setTimeout(function () {}, 600000)' >/dev/null 2>&1 &
HOLDER=$!
sleep 1
printf 'holder pid %s: %s\n' "$HOLDER" "$(ps -o comm=,args= -p "$HOLDER")"
printf '%s\n' "$HOLDER" > "$HOME_DIR/state/.lock"
printf 'fm-lock status before session: %s\n' "$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-lock.sh" status)"

dsh --profile "$PROFILE" --from-default-profile headless --dump-config >/dev/null 2>&1 || { echo "profile create failed"; exit 1; }
dsh plugin --profile "$PROFILE" add "@deepseek-ai/dsh-hooks-claude-code@$BASE_VERSION" >/dev/null 2>&1 || { echo "bridge install failed"; exit 1; }
printf -- '- id: permission\n  config:\n    defaultPreset: danger-full-access\n' > "$PROFILE_DIR/cordis.patch.yml"

( cd "$WORK" && FM_DSH_HARNESS=dsh FM_ROOT="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    dsh --profile "$PROFILE" --patch "$ROOT/.dsh/profile.patch.yml" \
    "Without using any tools, reply with ONLY the word PING." ) >"$TMP/out" 2>&1 || true

after=$(cat "$HOME_DIR/state/.lock" 2>/dev/null || true)
printf 'session reply: %s\n' "$(tail -1 "$TMP/out")"
printf 'lock before=%s after=%s holder still alive=%s\n' "$HOLDER" "${after:-<empty>}" "$(kill -0 "$HOLDER" 2>/dev/null && echo yes || echo no)"
if [ -n "$after" ] && [ "$after" != "$HOLDER" ] && ! kill -0 "$after" 2>/dev/null; then
  echo "RESULT: non-dsh-shaped live holder treated as stale; the session took the lock as its own (now-exited) host pid"
else
  echo "RESULT: UNEXPECTED - lock not taken by the session"
fi

# The digest the session actually received, from DSH's persisted session log.
enc=$(printf '%s' "$(cd "$WORK" && pwd -P)" | sed 's#/#-#g')
for f in "$HOME/.dsh/sessions/-${enc}--"/*/session.v3.jsonl.zstd; do
  echo "digest lines in $f:"
  zstd -dc "$f" | grep -o 'READ-ONLY SESSION[^"\\]*\|lock acquired[^"\\]*\|another live firstmate session holds the lock[^"\\]*' | sort -u
done
