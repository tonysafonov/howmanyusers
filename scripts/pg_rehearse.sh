#!/usr/bin/env bash
# Rehearses a Postgres MAJOR upgrade on the stand, with the commands you will run in production: start a temporary
# server of the new major, dump the old one with the NEW version's pg_dumpall, restore, analyze, then diff
# fingerprints (pg_fingerprint.sql) of both. Read-only for the old database; everything temporary is removed.
# Prints timings (the downtime estimate), restore errors, the fingerprint diff.
#
#   TARGET=root@10.0.0.1 PG_CONTAINER=stand-db-1 PG_USER=app PG_PASSWORD=secret PG_DB=app \
#     MIGRATION=alembic MD5_TABLES=users,orders scripts/pg_rehearse.sh
#
# Env: TARGET and PG_CONTAINER (the old database's container) are required, with PG_PASSWORD.
#   PG_USER (default postgres), PG_DB (default postgres), NEW_VERSION (default 17), IMAGE_FLAVOR (default alpine; ''
#   for the Debian image), PG_NET (docker network of the old database; default: its first one),
#   PG_HOST (the old database's name on that network; default PG_CONTAINER),
#   MIGRATION (alembic|drizzle|none, default none), MD5_TABLES (see pg_fingerprint.sql), KEEP=1 (keep the new
#   container and volume for a look; remove with docker rm -f / docker volume rm).
# Uses only ssh to TARGET (not env.sh). Do it on the stand's data, a copy of production's if you can; the dump
# time scales with size, so the timings here are a floor. A major upgrade needs a dump/restore or pg_upgrade: a
# volume of the old major cannot be started by the new one.
set -euo pipefail
: "${TARGET:?set TARGET=user@host}"; : "${PG_CONTAINER:?set PG_CONTAINER=<old db container>}"; : "${PG_PASSWORD:?set PG_PASSWORD}"
PG_USER=${PG_USER:-postgres}; PG_DB=${PG_DB:-postgres}; NEW_VERSION=${NEW_VERSION:-17}
FLAVOR=${IMAGE_FLAVOR-alpine}; IMAGE="postgres:$NEW_VERSION${FLAVOR:+-$FLAVOR}"
MIGRATION=${MIGRATION:-none}; MD5_TABLES=${MD5_TABLES:-}; PG_HOST=${PG_HOST:-$PG_CONTAINER}
HERE="$(cd "$(dirname "$0")" && pwd)"
SSH_OPTS=${SSH_OPTS:--o BatchMode=yes}

scp -q $SSH_OPTS "$HERE/pg_fingerprint.sql" "$TARGET:/tmp/pg_fingerprint.sql"
ssh $SSH_OPTS "$TARGET" env U="$PG_USER" PW="$PG_PASSWORD" D="$PG_DB" OLD="$PG_CONTAINER" OLDHOST="$PG_HOST" NET="${PG_NET:-}" \
  IMAGE="$IMAGE" MIG="$MIGRATION" MD5T="$MD5_TABLES" KEEP="${KEEP:-0}" bash -s <<'REMOTE'
set -euo pipefail
NEWC=pgrehearse-new; VOL=pgrehearse-data; DUMP=/tmp/pgrehearse.sql
[ -n "$NET" ] || NET=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$OLD" | awk '{print $1}')
cleanup() { [ "$KEEP" = 1 ] || { docker rm -f $NEWC >/dev/null 2>&1; docker volume rm -f $VOL >/dev/null 2>&1; rm -f $DUMP /tmp/pgrehearse.err; }; }
trap cleanup EXIT
docker rm -f $NEWC >/dev/null 2>&1 || true; docker volume rm -f $VOL >/dev/null 2>&1 || true
docker volume create $VOL >/dev/null
t0=$(date +%s)
docker run -d --name $NEWC --network "$NET" -v $VOL:/var/lib/postgresql/data \
  -e POSTGRES_USER="$U" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_DB=postgres "$IMAGE" >/dev/null
for _ in $(seq 60); do docker exec $NEWC pg_isready -U "$U" >/dev/null 2>&1 && break; sleep 1; done
t1=$(date +%s)
docker exec -e PGPASSWORD="$PW" $NEWC pg_dumpall -h "$OLDHOST" -p 5432 -U "$U" --no-role-passwords > $DUMP
t2=$(date +%s)
docker exec -i $NEWC psql -U "$U" -d postgres -q < $DUMP 2> /tmp/pgrehearse.err || true
docker exec $NEWC vacuumdb -U "$U" --all --analyze-only >/dev/null
t3=$(date +%s)
echo "dump size: $(du -h $DUMP | cut -f1); start new: $((t1-t0)) s, dump: $((t2-t1)) s, restore+analyze: $((t3-t2)) s"
echo "restore errors:"; grep ERROR /tmp/pgrehearse.err || echo "(none)"
fp() { docker exec -i "$1" psql -q -U "$U" -d "$D" -v migration="$MIG" -v md5_tables="$MD5T" -f - < /tmp/pg_fingerprint.sql; }
fp "$OLD" > /tmp/fp_old.txt; fp $NEWC > /tmp/fp_new.txt
echo "fingerprint lines: $(wc -l < /tmp/fp_old.txt)"; grep -E '^(rows|md5) ' /tmp/fp_old.txt | head -12
if diff /tmp/fp_old.txt /tmp/fp_new.txt; then echo "FINGERPRINT IDENTICAL"; else echo "FINGERPRINT DIFFERS (above)"; fi
docker exec $NEWC psql -U "$U" -d "$D" -Atc 'select version()' | cut -c1-60
rm -f /tmp/fp_old.txt /tmp/fp_new.txt
REMOTE
