#!/usr/bin/env bash
# Live drive of the documented launch boundary: a headless DSH session started
# through bin/fm-dsh-launch.sh from a shell that still carries CLAUDECODE (this
# driver runs under Claude Code). The only manual step is the documented bridge
# install; the launcher must apply the tracked patch, pass its own preflight,
# clear the foreign marker, and the session's first request must carry the
# firstmate digest naming harness dsh and owning a free fleet lock.
# A throwaway FM_HOME/FM_STATE_OVERRIDE keeps state out of the checkout.
set -u
ROOT=$(pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-dsh-launch.XXXXXX")
PROFILE=fmdshtestlaunch
PROFILE_DIR="$HOME/.dsh/profiles/$PROFILE"
cleanup() { rm -rf "$PROFILE_DIR" "$TMP"; }
trap cleanup EXIT

DSH_REAL=$(node -e 'console.log(require("node:fs").realpathSync(process.argv[1]))' "$(command -v dsh)")
BASE_VERSION=$(node -p "require(process.argv[1] + '/dsh-base/package.json').version" "$(dirname "$(dirname "$(dirname "$DSH_REAL")")")")
printf 'caller env: CLAUDECODE=%s FM_DSH_HARNESS=%s\n' "${CLAUDECODE:-unset}" "${FM_DSH_HARNESS:-unset}"

dsh --profile "$PROFILE" --from-default-profile headless --dump-config >/dev/null 2>&1 || { echo "profile create failed"; exit 1; }
dsh plugin --profile "$PROFILE" add "@deepseek-ai/dsh-hooks-claude-code@$BASE_VERSION" >/dev/null 2>&1 || { echo "bridge install failed"; exit 1; }

HOME_DIR="$TMP/home"; mkdir -p "$HOME_DIR"
start=$(date +%s)
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  "$ROOT/bin/fm-dsh-launch.sh" --profile "$PROFILE" "Without using any tools, reply with ONLY the word PING." >"$TMP/out" 2>&1
rc=$?
echo "launcher exit $rc; preflight + session output:"
sed 's/^/  | /' "$TMP/out"

held=$(cat "$HOME_DIR/state/.lock" 2>/dev/null || true)
printf 'lock after session: %s (alive now: %s)\n' "${held:-<none>}" "$( [ -n "$held" ] && kill -0 "$held" 2>/dev/null && echo yes || echo no)"
printf 'once-per-session gate: %s\n' "$(cat "$HOME_DIR/state/.dsh-sessionstart-delivered" 2>/dev/null || echo '<absent>')"

enc=$(printf '%s' "$ROOT" | sed 's#/#-#g')
for f in "$HOME/.dsh/sessions/-${enc}--"/*/session.v3.jsonl.zstd; do
  [ "$(stat -f %m "$f")" -ge "$start" ] || continue
  echo "digest lines the session's request carried ($f):"
  zstd -dc "$f" | grep -o 'READ-ONLY SESSION[^"\\]*\|lock acquired[^"\\]*\|another live firstmate session holds the lock[^"\\]*\|harness: [a-z-]*' | sort -u | sed 's/^/  /'
done
