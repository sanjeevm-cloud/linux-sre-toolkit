# System triage

When a Linux server feels slow, find the process behind it.
`triage.sh` checks the four usual suspects (CPU, memory, disk I/O and
network) and is safe to run on a server that's already struggling.

```bash
sudo ./triage.sh                        # full report, also saved to /var/log/linux-triage/
sudo TIMEOUT=5 TOP_N=10 ./triage.sh     # tune with environment variables
```

## What it runs

| Check | Command | What to look for |
|---|---|---|
| Load | `/proc/loadavg` | Load higher than the core count means work is queuing |
| Pressure | `/proc/pressure/*` | % of the last 10s that tasks were stalled on CPU, memory or I/O |
| Memory | `free -h` | Look at **available**, not free: cache is reclaimable |
| Disk space | `df -hPl` | Full filesystems. `-l` skips NFS, which can hang `df` |
| CPU | `top -b -n 2 -d 1` | What is busy **right now** (measured over 1s). `ps %CPU` is a lifetime average and can miss a process that just started spinning, so it is only the fallback |
| Memory | `ps --sort=-%mem` | RSS = real memory in use |
| Stuck | `ps -eo stat,wchan` | **D** = waiting on disk/NFS, can't be killed. **Z** = zombie; the parent must reap it |
| Disk I/O | `pidstat -d 1 2` | `kB_rd/s`, `kB_wr/s` per process |
| Network | `ss -s`, `ss -tunap` | Connection counts, and which process owns each socket |

Works on RHEL / Oracle Linux / Amazon Linux, Debian / Ubuntu and SUSE. If a
tool is missing, that check is skipped and the right install command is
printed (`dnf install sysstat`, `apt-get install sysstat`, and so on).

Must run as root: per-process disk I/O and socket owners are only visible
to root, so a non-root run exits instead of giving an incomplete report.
It also adds the `sbin` directories to `PATH`, so it works from cron, where
`PATH` is minimal (on RHEL, `ss` lives in `/usr/sbin`).

| Setting | Default | Meaning |
|---|---|---|
| `TIMEOUT` | 10 | seconds allowed per command |
| `DEADLINE` | 60 | seconds allowed for the whole run |
| `TOP_N` | 15 | rows in the CPU and memory lists |
| `KEEP_DAYS` | 14 | reports older than this are deleted |
| `REPORT_DIR` | `/var/log/linux-triage` | must be a root-owned directory, not a symlink |
| `LOCK_FILE` | `/run/linux-triage.lock` | stops two runs overlapping |

Reports and the lock live in root-owned directories on purpose. Under
`/tmp`, another user could plant a symlink there and make root overwrite
any file it points to.

## Why it can't hang

1. **Every command has a time limit.** `timeout -k 2` sends SIGTERM, then
   SIGKILL 2s later.
2. **Stuck processes are abandoned.** A process in D state ignores even
   SIGKILL, and `timeout` would wait on it forever. So the script polls,
   and after the limit it gives up on that command and moves on (`[STUCK]`).
3. **The whole run has a deadline** (60s by default). Anything left is `[SKIPPED]`.
4. **Known hang sources are avoided:** no `hostname -f` (DNS lookup), no
   network filesystems in `df`.

Exit codes: `0` all OK, `1` some checks didn't finish or a tool is missing
(the report is still useful), `2` setup problem (such as not running as root), `3` already running.

## Design notes

- **Too gentle is too slow.** At `nice 19` the script took 47–64s on a
  CPU-saturated box and blew its own deadline. At nice 10 it takes about 10s.
- **Leaked lock.** Commands inherited the lock's file descriptor, so one
  stuck command would have blocked every future run. Fixed with `9>&-`.
- **Signals in a pipeline.** With `checks | tee`, SIGTERM stopped the main
  shell but the checks kept running in the pipeline. Fixed by using
  `exec > >(tee ...)` so the checks run in the main shell.

## Tests

```bash
sudo tests/run_tests.sh     # 35 checks, ~80s
```

Each failure is faked by putting a script first on `PATH`: a command that
hangs, a `timeout` that never returns (the D-state case), missing tools, a
second concurrent run, SIGTERM and SIGHUP mid-run, symlink attacks on the
lock and report paths, a non-root run, and a CPU decoy that `ps` would
rank wrongly. CI runs them on Ubuntu, Debian,
Oracle Linux and Amazon Linux.

## Try it yourself

On a throwaway VM, start one of these, run `sudo ./triage.sh`, and find it:

```bash
stress-ng --cpu "$(nproc)" --timeout 60s &            # CPU
stress-ng --vm 1 --vm-bytes 70% --timeout 60s &       # memory
stress-ng --hdd 2 --timeout 60s &                     # disk I/O
bash -c 'sleep 1 & exec sleep 120' &                  # zombie
```
