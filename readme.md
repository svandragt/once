# once

**Run any command — but never twice too soon.**

`once` is a lightweight Bash wrapper that ensures a command executes **at most once per time period** (hour/day/week/month) or within a **custom cooldown window** (like “6h” or “2d”).
It’s perfect for scripts, CI jobs, or ad-hoc shell tasks you don’t want to repeat accidentally.

Instead of scheduling jobs in cron, you just prefix your command and run it however many times you want:

```bash
# Run it every time you login or something.
$ once --period day -- ./backup.sh
$ once --window 6h -- make deploy

# only once though
$ once --window 1h -- echo 'yoohoo'
yoohoo
$ once --window 1h -- echo 'yoohoo'
Skipped: ran 1s ago; window 1h.
```

`once` automatically:

* Creates a unique hash for the command (including args and working dir).
* Tracks when it was last run.
* Skips repeated runs within the defined time window.
* Prevents concurrent duplicates via lockfiles.
* Works anywhere — interactive shells, scripts, CI — no cron required.

In short: **run anything, but never twice too soon.**


---

## 🚀 Quick Start

```bash
# Safe install (download → review → install)
curl -fsSL https://raw.githubusercontent.com/svandragt/once/main/once.sh -o /tmp/once.sh
less /tmp/once.sh # inspect before running and making it executable

sudo install -m 0755 /tmp/once.sh /usr/local/bin/once
chmod +x /usr/local/bin/once

# EXAMPLES
# Run something once per day
once --period day -- ./backup.sh

# Or with a rolling cooldown
once --window 6h -- ./sync.sh

# Explain what would happen
once --explain --dry-run -- ./job.sh
```

---

## 🧠 How it works

* Each command’s **identity** is based on its executable path, arguments, working directory, and an optional `--key-extra` string.
* The identity is **hashed** (SHA-256) and recorded under:

  ```
  ~/.local/state/once/
  ```
* When invoked again, `once` checks whether that command has already run during:

  * The same **calendar period** (`hour`, `day`, `week`, `month`), **or**
  * Within a **rolling window** (e.g., 6h or 2d).
* If it has, it **skips** execution and exits with code **3**.
* It uses atomic **lock directories** to prevent concurrent runs.

---

## 🧩 Usage

```bash
once [--period {hour|day|week|month} | --window {Nh|Nd}] [options] -- <command> [args...]
```

### Options

| Option              | Description                                                                     |
| ------------------- | ------------------------------------------------------------------------------- |
| `--period <p>`      | Use calendar periods (hour/day/week/month).                                     |
| `--window <d>`      | Use a rolling cooldown (e.g. `6h`, `2d`).                                       |
| `--key-extra <s>`   | Add extra material to identity key (useful for environments like prod/staging). |
| `--state-dir <dir>` | Override state directory (default: `$XDG_STATE_HOME/once`).                     |
| `--force`           | Always run, ignoring cooldown.                                                  |
| `--dry-run`         | Don’t execute — just print what would happen.                                   |
| `--explain`         | Show derived hash, stamp path, etc.                                             |
| `-h, --help`        | Show help.                                                                      |

### Exit codes

| Code | Meaning                                                    |
| ---- | ---------------------------------------------------------- |
| 0    | Command executed successfully (or would with `--dry-run`). |
| 1    | Underlying command failed.                                 |
| 3    | Skipped — already ran in this period/window.               |
| 4    | Another instance already running (lock held).              |

---

## 🧪 Examples

```bash
# Once per hour
once --period hour -- ./poll-api.sh

# Once per week (ISO weeks)
once --period week -- ./report.sh

# Once every 36 hours
once --window 36h -- ./rebuild-index.sh

# Add environment context to key
once --period day --key-extra prod -- ./backup.sh

# Forced run ignoring window
once --force -- ./backup.sh
```

---

## ⚙️ Internals

* **Hashes:** SHA-256 of a canonical identity string (exe, args, cwd, key-extra).
* **State:**

  * Period mode: `~/.local/state/once/periods/YYYY-MM-DD/<hash>.stamp`
  * Window mode: `~/.local/state/once/windows/<hash>.stamp`
* **Locks:** Atomic `mkdir` in `~/.local/state/once/locks/<hash>.lock`
* **Concurrency:** Locks prevent two simultaneous invocations of the same job.
* **Security:** State dir is `0700` (owner-only). No arguments are logged by default.

---

## 🧹 Cleanup

Stamps accumulate over time. You can safely remove old entries:

```bash
find ~/.local/state/once/periods -type d -mtime +60 -exec rm -rf {} +
find ~/.local/state/once/windows -type f -mtime +90 -delete
```

A future version will include a `--gc` command for automatic cleanup.

---

## 💡 When to use `once`

✅ You should use it when:

* You trigger tasks manually or via scripts, but want **idempotent frequency control**.
* You want to **avoid cron**, or you’re running in **containers/CI** where time-based scheduling isn’t reliable.
* You have multiple scripts sharing cooldown logic.

❌ You don’t need it when:

* Your task is already handled by cron/systemd timers/anacron.
* You need distributed coordination across multiple hosts (use Redis locks, etc. instead).

---

## 📜 License

GPL © 2025 Sander van Dragt
