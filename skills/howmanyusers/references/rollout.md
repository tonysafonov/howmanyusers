# Rollout: the handoff and the Postgres rehearsal

The lab ends with a recommendation, not a deploy (non-negotiable 1). Two tools turn it into something a release can
follow: a handoff document and, when the database's major version is part of the plan, a rehearsal on the stand.

## The handoff (`templates/handoff.md`)

Write it right after the campaign, while you remember which fix needs which config edit. It is for the person who
releases later; the report (`templates/report.md`) is for readers who want to check the numbers.

| Section | Holds |
|---|---|
| What the stand proved | production-as-is vs everything-applied, same journey, same box; stand vs production differences |
| What a normal release carries | one row per change: commit, and one command or screen that proves it after release |
| Production-only config edits | what a release does not ship: published ports, proxy routes, workers, memory limits, pool sizes; snippet, what staging already proves, after-deploy check |
| Security findings (private) | evidence, fix, done box. Keep this file private or strip the section |
| Rollout order | security edits first, then the release, then config edits one at a time, capacity last |
| Baseline | the user-facing metric before, with source and filters, to compare after two weeks |

Rules that held up:

- **Every item has its own check.** "Port closed" is `nc -vz -w 5 <host> <port>` failing from an outside machine;
  "pool fits" is the arithmetic `processes x (pool + overflow) + other clients < max_connections`.
- **Separate what a release carries from what it doesn't.** The config edits are the ones that get forgotten.
- **Capacity changes last and alone.** Workers x memory x pool move together; watch `RestartCount` for a day.
- **Published Docker ports bypass the host firewall.** Check from outside, not with `ufw status`; `preflight.sh`
  does it for the stand, do it for production too.
- Tell the owner what is not worth shipping yet, with the reason.

## Rehearsing a Postgres major upgrade (`scripts/pg_rehearse.sh`)

A volume of one major cannot be opened by the next, so the upgrade is a dump and restore (or `pg_upgrade`). Rehearse the
exact commands on the stand's data first:

```bash
TARGET=root@<target> PG_CONTAINER=<old db container> PG_USER=<user> PG_PASSWORD=<pw> PG_DB=<db> \
  NEW_VERSION=17 MIGRATION=alembic MD5_TABLES=users,orders $S/scripts/pg_rehearse.sh
```

It starts a temporary server of the new major on the same network, dumps the old one with the **new** version's
`pg_dumpall`, restores, runs `vacuumdb --analyze-only`, and diffs `pg_fingerprint.sql` of both. It prints the
timings (the dump + restore time is your downtime floor), every restore `ERROR`, and `FINGERPRINT IDENTICAL` or the
diff. The old database is only read; the temporary container, volume and dump are removed (`KEEP=1` keeps them).

`pg_fingerprint.sql` can also be run on its own before and after a risky migration:
`psql -q -U <u> -d <db> -v migration=alembic|drizzle|none -v md5_tables=a,b -f scripts/pg_fingerprint.sql`.
It prints the migration version, every table's row count, sequences, constraint counts per type, index count,
invalid indexes, enums, extensions and an md5 of every row of the tables you name. Counts catch lost rows; the md5
catches changed ones, so name the tables where that would hurt (users, payments).

Caveats: synthetic stand data gives the procedure and a time floor, not production's real dump time; pick the new
major deliberately (the newest one supported by your driver and extensions); a major upgrade changes planner
behaviour, so re-run a hold afterwards, twice if it fails at the edge (load.md: repeat at the edge).
