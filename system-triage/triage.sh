#!/usr/bin/env bash
#
# triage.sh - which process is eating CPU, memory, disk I/O or network?
#
# Safe to run on a struggling server:
#   - every command has a time limit (SIGTERM, then SIGKILL)
#   - a command stuck in D state (unkillable) is skipped, never waited on
#   - the whole run stops at a deadline
#   - a missing tool is skipped with an install hint, not a crash
#
# Usage:   sudo ./triage.sh          (must run as root)
# Tuning:  sudo TIMEOUT=5 DEADLINE=30 TOP_N=10 ./triage.sh
#
# Exit codes: 0 all checks OK, 1 some checks did not finish,
#             2 setup problem (e.g. not root), 3 another run is in progress

set -uo pipefail
export LC_ALL=C     # predictable number formats for parsing (0.5, not 0,5)

# cron and some sudo setups give a minimal PATH (/usr/bin:/bin), but on
# RHEL / Oracle Linux `ss` lives in /usr/sbin. Add the sbin directories.
PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

TIMEOUT=${TIMEOUT:-10}      # seconds allowed per command
DEADLINE=${DEADLINE:-60}    # seconds allowed for the whole run
TOP_N=${TOP_N:-15}          # rows in the top-CPU and top-memory lists
KEEP_DAYS=${KEEP_DAYS:-14}  # delete reports older than this
# Root-owned locations only: a lock or report under /tmp could be a symlink
# planted by another user, and root would overwrite whatever it points to.
REPORT_DIR=${REPORT_DIR:-/var/log/linux-triage}
LOCK_FILE=${LOCK_FILE:-/run/linux-triage.lock}

FAILED=()   # checks that did not finish cleanly
OUT=""      # output file of the last command run

section() { printf '\n===== %s =====\n' "$1"; }
have()    { command -v "$1" >/dev/null 2>&1; }

# show [MAX] - print the last command's output, saying so if it was cut.
show() {
    local max=${1:-200} total
    total=$(wc -l <"$OUT")
    head -n "$max" "$OUT"
    (( total > max )) && echo "... $(( total - max )) more lines not shown"
    return 0
}

# skip_tool TOOL - report a missing tool and count it in the summary.
skip_tool() {
    echo "[SKIPPED] $1 not found: $(install_hint "$1")"
    FAILED+=("$1: not installed")
}

# The install command for a missing tool depends on the distro family.
install_hint() {
    local pkg
    case $1 in
        pidstat) pkg=sysstat ;;
        ss)      pkg=iproute2 ;;
        *)       pkg=procps ;;
    esac
    if have apt-get; then
        echo "apt-get install $pkg"
    elif have dnf || have yum; then           # RHEL, Oracle Linux, Amazon Linux
        [[ $pkg == procps ]]   && pkg=procps-ng
        [[ $pkg == iproute2 ]] && pkg=iproute
        if have dnf; then echo "dnf install $pkg"; else echo "yum install $pkg"; fi
    elif have zypper; then
        echo "zypper install $pkg"
    else
        echo "install the '$pkg' package"
    fi
}

# run NAME COMMAND... - run a command with a time limit; output goes to $OUT.
run() {
    local name=$1; shift
    local left=$(( DEADLINE - SECONDS ))
    if (( left <= 0 )); then
        OUT=/dev/null       # so `show` doesn't print the previous output
        echo "[SKIPPED] out of time"
        FAILED+=("$name: skipped, deadline reached")
        return 1
    fi
    local limit=$(( TIMEOUT < left ? TIMEOUT : left ))
    OUT=$(mktemp -p "$WORK")

    # 9>&- : don't pass the lock to the command, or a stuck command would
    # hold it forever and block every future run.
    timeout -k 2 "$limit" "$@" </dev/null >"$OUT" 2>&1 9>&- &
    local pid=$!

    # Don't just `wait`: a process stuck in D state ignores even SIGKILL,
    # and timeout would wait for it forever. Poll, and give up after a while.
    local give_up=$(( SECONDS + limit + 3 ))
    while kill -0 "$pid" 2>/dev/null; do
        if (( SECONDS >= give_up )); then
            kill -9 "$pid" 2>/dev/null
            disown "$pid" 2>/dev/null
            echo "[STUCK] $name did not respond even to SIGKILL; skipped"
            FAILED+=("$name: stuck (likely D state)")
            return 1
        fi
        sleep 0.2
    done

    local rc=0
    wait "$pid" || rc=$?
    case $rc in
        0)       ;;
        124|137) echo "[TIMEOUT] $name took over ${limit}s; partial output:"
                 FAILED+=("$name: timed out") ;;
        *)       echo "[FAILED] $name exited with code $rc"
                 FAILED+=("$name: exit code $rc") ;;
    esac
    return "$rc"
}

check_system() {
    section "System"
    local l1 l5 l15 _ os="Linux"
    read -r l1 l5 l15 _ </proc/loadavg
    [[ -r /etc/os-release ]] && os=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')

    echo "Host   : $(uname -n)"       # not `hostname -f`: that does a DNS lookup
    echo "OS     : $os"
    echo "Kernel : $(uname -r)"
    echo "Cores  : $(nproc)"
    echo "Load   : $l1 $l5 $l15 (1/5/15 min, compare with cores)"

    # Pressure Stall Information: % of the last 10s that tasks were waiting.
    # The files can exist but be unreadable when PSI is disabled at boot.
    local r psi=""
    for r in cpu memory io; do
        psi+=" $r $(awk '/^some/{print $2}' "/proc/pressure/$r" 2>/dev/null || echo n/a)"
    done
    [[ -d /proc/pressure ]] && echo "Stalled:$psi"
}

check_memory() {
    section "Memory"
    if have free; then
        run "free" free -h; show
    else
        skip_tool free
    fi

    section "Disk space (local filesystems)"
    run "df" df -hPl; show      # -l skips NFS mounts, which can hang df
}

check_top_processes() {
    # ps %CPU is averaged over the process's whole life, so a long-running
    # process that just started spinning would rank low. top's second
    # snapshot is measured over the last second: what is busy right now.
    if have top; then
        section "Top $TOP_N by CPU right now  (top, 1s sample)"
        # HOME=/nonexistent ignores any personal .toprc that changes the sort;
        # COLUMNS=512 stops top cutting command names to 10 characters.
        run "top" env HOME=/nonexistent COLUMNS=512 top -b -n 2 -d 1
        awk '/^ *PID /{n++} n == 2' "$OUT" | head -n $(( TOP_N + 1 ))
    else
        section "Top $TOP_N by CPU  (ps: lifetime average, top not found)"
        run "ps cpu" ps -eo pid,user,stat,%cpu,%mem,etime,comm --sort=-%cpu
        show $(( TOP_N + 1 ))
    fi

    section "Top $TOP_N by memory  (RSS in KiB)"
    run "ps memory" ps -eo pid,user,stat,%cpu,%mem,rss,etime,comm --sort=-%mem
    show $(( TOP_N + 1 ))
}

check_stuck_processes() {
    section "Stuck (D) and zombie (Z) processes"
    run "ps state" ps -eo pid,ppid,user,stat,etime,wchan:32,comm || return
    local found
    found=$(awk 'NR > 1 && $4 ~ /^[DZ]/' "$OUT")
    if [[ -z $found ]]; then
        echo "none"
    else
        head -n 1 "$OUT"
        echo "$found"
    fi
}

check_disk_io() {
    section "Disk I/O per process  (pidstat -d 1 2)"
    if ! have pidstat; then
        skip_tool pidstat
        return
    fi
    run "pidstat" pidstat -d 1 2; show
}

check_network() {
    section "Network"
    if ! have ss; then
        skip_tool ss
        return
    fi
    run "ss summary" ss -s; show
    echo
    run "ss sockets" ss -tunap; show 50     # -p shows the owning process
}

summary() {
    section "Summary"
    if (( ${#FAILED[@]} == 0 )); then
        echo "All checks completed in ${SECONDS}s."
        return 0
    fi
    echo "Finished in ${SECONDS}s. These checks did not complete:"
    printf '  - %s\n' "${FAILED[@]}"
    return 1
}

cleanup() {
    # shellcheck disable=SC2046  # one PID per word is what we want
    kill $(jobs -p) 2>/dev/null     # stop any command still running
    rm -rf "$WORK"
    if [[ -n ${TEE_PID:-} ]]; then  # let tee finish writing the report
        exec >&- 2>&-
        wait "$TEE_PID" 2>/dev/null
    fi
}

# ---------------------------------------------------------------- setup ----
case ${1:-} in
    "")        ;;
    -h|--help) sed -n '3,15p' "$0" | cut -c3-; exit 0 ;;
    *)         echo "Unknown option: $1 (try -h)" >&2; exit 2 ;;
esac
[[ $(uname -s) == Linux ]] || { echo "Linux only" >&2; exit 2; }
# Root is needed to see every user's disk I/O and which process owns each
# socket. Without it the report would be quietly incomplete, so stop here.
if (( EUID != 0 )); then
    echo "Run as root: sudo $0" >&2
    exit 2
fi
for var in TIMEOUT DEADLINE TOP_N KEEP_DAYS; do
    [[ ${!var} =~ ^[1-9][0-9]*$ ]] || { echo "$var must be a positive number" >&2; exit 2; }
done
for tool in ps timeout; do
    have "$tool" || { echo "$tool is required: $(install_hint "$tool")" >&2; exit 2; }
done

# Only one run at a time. `>>` never truncates, even if the path is a link.
if have flock; then
    exec 9>>"$LOCK_FILE" || { echo "Cannot open lock file $LOCK_FILE" >&2; exit 2; }
    flock -n 9 || { echo "Another triage.sh is already running" >&2; exit 3; }
else
    echo "Warning: flock not found, running without a lock" >&2
fi

# Lower priority, but not the lowest: at nice 19 the script itself gets
# starved on a CPU-saturated box (measured 47-64s vs 10s at nice 10).
renice -n 10 -p $$ >/dev/null 2>&1

# Save a private copy of the report (it lists processes and connections).
# Only write into a real directory owned by root, never through a symlink.
umask 077
mkdir -p "$REPORT_DIR" 2>/dev/null
if [[ -d $REPORT_DIR && ! -L $REPORT_DIR && $(stat -c %u "$REPORT_DIR") == 0 ]]; then
    find "$REPORT_DIR" -maxdepth 1 -name '*.log' -mtime +"$KEEP_DAYS" -delete 2>/dev/null
    REPORT="$REPORT_DIR/$(uname -n)_$(date +%Y%m%d_%H%M%S).log"
    echo "Report: $REPORT"
    exec > >(tee "$REPORT" 9>&-) 2>&1
    TEE_PID=$!
else
    echo "Warning: $REPORT_DIR is not a root-owned directory; not saving a report" >&2
fi

WORK=$(mktemp -d)
trap cleanup EXIT
trap 'exit 129' HUP     # SSH session dropped
trap 'exit 130' INT
trap 'exit 143' TERM

check_system
check_memory
check_top_processes
check_stuck_processes
check_disk_io
check_network
summary
