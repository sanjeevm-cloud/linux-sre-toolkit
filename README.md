# linux-sre-toolkit

Hands-on SRE tooling and runbooks for diagnosing production Linux systems.
Each module is a tool you can run on a real server, plus the tests and
notes that explain why it works the way it does.

| Module | What it does |
|---|---|
| [system-triage](system-triage/) | First-responder snapshot of a Linux host: finds which process is eating CPU, memory, disk I/O or network. Safe on a struggling server: time limits on every command, a deadline, and it never hangs on stuck processes |

## Quick start

```bash
git clone <this repo> && cd linux-sre-toolkit
sudo system-triage/triage.sh
make test        # full test suite
make lint        # shellcheck
```

## Principles

- **Safe on a sick box.** Every probe is time-bounded; nothing can hang the tool.
- **Honest output.** Each check reports OK / TIMEOUT / UNRESPONSIVE /
  FAILED / SKIPPED, and the exit code reflects it.
- **Tested by breaking it.** Failure modes are simulated in tests and run in
  CI across distro families.

## License

MIT, see [LICENSE](LICENSE).
