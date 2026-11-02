#!/usr/bin/env bash
# A transient failure of an apt download is retried, and a persistent one ends
# the step after the last try.
set -euo pipefail
cd "$(dirname "$0")/.."
failed=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A fake apt-get that fails (as apt does on a 503) until its Nth call.
mkdir "$tmp/bin"
cat >"$tmp/bin/apt-get" <<'F'
#!/usr/bin/env bash
n=$(($(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_COUNT"
if ((n < FAKE_SUCCEED_AT)); then
	echo "E: Failed to fetch ... 503  Service Unavailable" >&2
	exit 100
fi
F
chmod +x "$tmp/bin/apt-get"

# A fake timeout that records the limit it was given, then runs the command.
cat >"$tmp/bin/timeout" <<'F'
#!/usr/bin/env bash
[[ $1 == -k ]] && shift 2
echo "$1" >>"$FAKE_LIMITS"
shift
exec "$@"
F
chmod +x "$tmp/bin/timeout"

run() { # succeed-at, apt-get subcommand -> "exit-code calls limit"
	echo 0 >"$tmp/count"
	: >"$tmp/limits"
	local rc=0
	(
		export PATH="$tmp/bin:$PATH" FAKE_COUNT="$tmp/count" FAKE_SUCCEED_AT=$1 FAKE_LIMITS="$tmp/limits"
		# shellcheck disable=SC1091
		source toolsets/lib.sh
		sleep() { :; }
		apt_get "$2" -y
	) 2>"$tmp/err" || rc=$?
	echo "$rc $(cat "$tmp/count") $(head -n 1 "$tmp/limits")"
}

# An install download: three tries, TRY_MAX_TIME each.
[[ $(run 3 install) == "0 3 300" ]] || { echo "FAIL: two 503s then success: got $(run 3 install)"; failed=1; }
grep -q 'retry: try 2/3 failed' "$tmp/err" || { echo "FAIL: a retry is not logged"; failed=1; }
[[ $(run 99 install) == "100 3 300" ]] || { echo "FAIL: persistent 503 should end after 3 tries: got $(run 99 install)"; failed=1; }
# An index update: two tries, UPDATE_MAX_TIME each.
[[ $(run 2 update) == "0 2 1200" ]] || { echo "FAIL: update, one 503 then success: got $(run 2 update)"; failed=1; }
[[ $(run 99 update) == "100 2 1200" ]] || { echo "FAIL: persistent 503 should end an update after 2 tries: got $(run 99 update)"; failed=1; }

# apt's own retries are on for the whole build, and off again when it ends.
grep -q 'Acquire::Retries' toolsets/apt-snapshot.sh || { echo "FAIL: apt-snapshot.sh sets no Acquire::Retries"; failed=1; }
grep -qF "rm -f \"\$retries\"" toolsets/apt-snapshot.sh || { echo "FAIL: restore leaves the retries file"; failed=1; }
grep -q 'retry npx --yes "playwright@' ubuntu-24.04-container/Dockerfile || { echo "FAIL: install-deps is not retried"; failed=1; }

((failed == 0)) || exit 1
echo "apt_retry_test: ok"
