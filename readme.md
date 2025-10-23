**Once**

`once` is a lightweight Bash wrapper that ensures any command runs **at most once per time period** — for example, once per hour, day, week, month, or within a custom cooldown window like “6h.”

Instead of scheduling jobs in cron, you just prefix your command:

```bash
# examples
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
