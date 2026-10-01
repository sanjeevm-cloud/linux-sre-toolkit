#!/usr/bin/env bash
#
# Tests for triage.sh. Plain bash, no framework.
#
# Failures are faked by putting a script first on PATH:
#   slow/ps       - hangs on the memory check     -> expect [TIMEOUT]
#   stuck/timeout - never returns on the D/Z check -> expect [STUCK]
#                   (models timeout(1) waiting on a D-state process)

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/triage.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOCK_FILE="$TMP/lock" REPORT_DIR="$TMP/reports"

pass=0 fail=0
check() {   # check "description" command...
    if "${@:2}"; then pass=$((pass + 1)); echo "  ok    $1"
    else              fail=$((fail + 1)); echo "  FAIL  $1"; fi
}
triage() {  # triage OUTFILE [env assignments...] - sets RC and TIME
    local out=$1; shift
    local start=$SECONDS
    env "$@" "$SCRIPT" >"$out" 2>&1
    RC=$?
    TIME=$(( SECONDS - start ))
}
contains() { grep -q -- "$2" "$1"; }

# Fake commands.
mkdir -p "$TMP/slow" "$TMP/stuck"
cat >"$TMP/slow/ps" <<EOF
#!/usr/bin/env bash
[[ "\$*" == *--sort=-%mem* ]] && exec sleep 300
exec $(command -v ps) "\$@"
EOF
cat >"$TMP/stuck/timeout" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *wchan* ]]; then trap '' TERM; while :; do sleep 1; done; fi
exec $(command -v timeout) "\$@"
EOF
chmod +x "$TMP"/*/*

echo "== basics"
check "bash syntax is valid"      bash -n "$SCRIPT"
if command -v shellcheck >/dev/null; then
    check "shellcheck is clean"   shellcheck "$SCRIPT" "$0"
fi
"$SCRIPT" -h >"$TMP/help" 2>&1
check "-h shows usage"            contains "$TMP/help" "Usage:"
triage "$TMP/bad" TIMEOUT=abc
check "bad TIMEOUT exits 2"       test "$RC" -eq 2
"$SCRIPT" --bogus >/dev/null 2>&1
check "unknown option exits 2"    test $? -eq 2
if (( EUID == 0 )) && command -v setpriv >/dev/null; then
    # Run once as the unprivileged 'nobody' user.
    cp "$SCRIPT" "$TMP/triage_copy.sh" && chmod 755 "$TMP" "$TMP/triage_copy.sh"
    setpriv --reuid=65534 --regid=65534 --clear-groups \
        env LOCK_FILE="$TMP/nobody.lock" "$TMP/triage_copy.sh" >"$TMP/nonroot" 2>&1
    RC=$?
    check "non-root exits 2"          test "$RC" -eq 2
    check "non-root says use sudo"    contains "$TMP/nonroot" "Run as root: sudo"
fi

echo "== normal run"
triage "$TMP/ok" TOP_N=3
check "exits 0"                   test "$RC" -eq 0
check "shows the OS"              contains "$TMP/ok" "OS     :"
check "all checks completed"      contains "$TMP/ok" "All checks completed"
report=$(find "$REPORT_DIR" -name '*.log' | head -n 1)
check "report saved, owner-only"  test "$(stat -c %a "${report:-/none}" 2>/dev/null)" = 600

echo "== a command hangs"
triage "$TMP/slow.out" PATH="$TMP/slow:$PATH" TIMEOUT=2 TOP_N=2
check "reports TIMEOUT"           contains "$TMP/slow.out" "\[TIMEOUT\] ps memory"
check "keeps going"               contains "$TMP/slow.out" "Stuck (D) and zombie"
check "exits 1"                   test "$RC" -eq 1
check "finishes quickly (<20s)"   test "$TIME" -lt 20

echo "== a command is stuck (D state)"
triage "$TMP/stuck.out" PATH="$TMP/stuck:$PATH" TIMEOUT=2 TOP_N=2
check "reports STUCK"             contains "$TMP/stuck.out" "\[STUCK\] ps state"
check "finishes quickly (<20s)"   test "$TIME" -lt 20
triage "$TMP/after.out" TOP_N=2
check "next run is not locked out" test "$RC" -ne 3

echo "== deadline"
triage "$TMP/dl.out" PATH="$TMP/slow:$PATH" TIMEOUT=3 DEADLINE=3
check "skips what's left"         contains "$TMP/dl.out" "\[SKIPPED\] out of time"
# A skipped step must not print the previous step's output under its heading:
# df prints a marker then hangs past the deadline; every later step is skipped.
mkdir -p "$TMP/marker"
printf '#!/usr/bin/env bash\necho STALE-MARKER\nexec sleep 300\n' >"$TMP/marker/df"
chmod +x "$TMP/marker/df"
triage "$TMP/stale.out" PATH="$TMP/marker:$PATH" DEADLINE=3
check "skipped steps print nothing stale" test "$(grep -c STALE-MARKER "$TMP/stale.out")" -eq 1
check "stops near deadline (<12s)" test "$TIME" -lt 12

echo "== one run at a time"
PATH="$TMP/slow:$PATH" TIMEOUT=6 "$SCRIPT" >/dev/null 2>&1 &
first=$!
sleep 1
triage "$TMP/lock.out"
check "second run exits 3"        test "$RC" -eq 3
wait "$first"

echo "== stopped with SIGTERM"
# TIMEOUT=31 tags this run's commands so we can check none are left behind.
PATH="$TMP/slow:$PATH" TIMEOUT=31 "$SCRIPT" >/dev/null 2>&1 &
pid=$!
sleep 3
kill -TERM "$pid"
wait "$pid"
check "exits 143"                 test $? -eq 143
sleep 1
check "no commands left running"  test -z "$(pgrep -f '^timeout -k 2 31 ')"

echo "== stopped by SSH disconnect (SIGHUP)"
PATH="$TMP/slow:$PATH" TIMEOUT=29 "$SCRIPT" >/dev/null 2>&1 &
pid=$!
sleep 3
kill -HUP "$pid"
wait "$pid"
check "exits 129"                 test $? -eq 129
sleep 1
check "no commands left running"  test -z "$(pgrep -f '^timeout -k 2 29 ')"

echo "== CPU check shows what is busy right now"
# decoy: busy for 3s, then idle  -> high lifetime average, idle now
# hog:   idle for 4s, then busy  -> lower lifetime average, busy now
# ps (lifetime average) would rank the decoy first; the right answer is the hog.
bash -c 'end=$((SECONDS + 3)); while (( SECONDS < end )); do :; done; exec sleep 60' &
decoy=$!
bash -c 'sleep 4; while :; do :; done' &
hog=$!
sleep 6
triage "$TMP/cpu.out" TOP_N=1
kill "$decoy" "$hog"
first=$(awk '/Top 1 by CPU/{f=1; next} f && /^ *[0-9]/{print $1; exit}' "$TMP/cpu.out")
check "ranks what is busy now, not the lifetime average" test "$first" = "$hog"

echo "== symlink attacks"
echo "important" >"$TMP/victim"
ln -s "$TMP/victim" "$TMP/evil.lock"
triage "$TMP/sym1.out" LOCK_FILE="$TMP/evil.lock" TOP_N=2
check "lock symlink does not truncate its target" test "$(cat "$TMP/victim")" = important
mkdir -p "$TMP/realdir"
ln -s "$TMP/realdir" "$TMP/linkdir"
triage "$TMP/sym2.out" REPORT_DIR="$TMP/linkdir" TOP_N=2
check "refuses a symlinked report dir" contains "$TMP/sym2.out" "not a root-owned directory"
check "writes nothing through it"      test -z "$(ls -A "$TMP/realdir")"

echo "== tools missing"
mkdir -p "$TMP/min"
for c in bash env ps timeout flock renice uname nproc id mktemp rm head awk \
         sed tr grep sleep kill tee cat df mkdir date stat find wc; do
    p=$(command -v "$c") && ln -sf "$p" "$TMP/min/$c"
done
triage "$TMP/min.out" PATH="$TMP/min" TOP_N=2
check "skips them, doesn't crash" contains "$TMP/min.out" "\[SKIPPED\] pidstat not found"
check "prints an install command" grep -qE "(apt-get|dnf|yum|zypper) install|install the" "$TMP/min.out"
check "falls back to ps for CPU"   contains "$TMP/min.out" "ps: lifetime average, top not found"
check "summary lists what's missing" contains "$TMP/min.out" "pidstat: not installed"
check "exits 1 (report incomplete)" test "$RC" -eq 1

echo
echo "passed: $pass  failed: $fail"
(( fail == 0 ))
