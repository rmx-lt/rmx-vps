#!/bin/bash
# rmx-ci backup -> change the data -> rmx-ci restore, against a throwaway
# TimescaleDB container named like the real one (probe-db). Needs Docker and
# root. Run from the repo: sudo ansible/test/db-roundtrip.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
CI=$REPO/ansible/ci/rmx-ci.sh
IMAGE=$(sed -n 's/^ *image: \(timescale\/timescaledb:.*\)/\1/p' "$REPO/services/probe/compose.yaml")
WORK=$(mktemp -d)
trap 'docker rm -f probe-db >/dev/null 2>&1 || true; rm -rf "$WORK" "$REPO/services/mosquitto/data" "$REPO/services/caddy/firmware"' EXIT

psql() { docker exec -i probe-db psql -U probe -d "${DB:-probe}" -v ON_ERROR_STOP=1 -tA "$@"; }

docker rm -f probe-db >/dev/null 2>&1 || true
docker run -d --name probe-db -e POSTGRES_USER=probe -e POSTGRES_DB=probe \
	-e POSTGRES_PASSWORD=test -e NO_TS_TUNE=true "$IMAGE" >/dev/null
for _ in $(seq 60); do docker exec probe-db pg_isready -U probe -q && break; sleep 1; done
sleep 3 # the image restarts postgres once after its init scripts
for _ in $(seq 60); do docker exec probe-db pg_isready -U probe -q && break; sleep 1; done

psql -q -c "CREATE EXTENSION IF NOT EXISTS timescaledb" \
	-c "CREATE TABLE readings(ts timestamptz NOT NULL, v int)" \
	-c "SELECT create_hypertable('readings','ts')" \
	-c "INSERT INTO readings SELECT now() - i * interval '1 hour', i FROM generate_series(1,500) i" >/dev/null
before=$(psql -c "SELECT count(*), sum(v) FROM readings")
echo "before: $before"

mkdir -p "$REPO/services/mosquitto/data/store"
echo "retained-message-store" >"$REPO/services/mosquitto/data/store/mosquitto.db"
mkdir -p "$REPO/services/caddy/firmware/probe"
echo "firmware-image" >"$REPO/services/caddy/firmware/probe/app.bin"

RMX_REPO=$REPO "$CI" backup >"$WORK/backup.tar.gz"
listing=$(tar -tzf "$WORK/backup.tar.gz")
grep -qx './probe.dump' <<<"$listing"
grep -q 'services/mosquitto/data/store/mosquitto.db' <<<"$listing"
grep -q 'services/caddy/firmware/probe/app.bin' <<<"$listing"

psql -q -c "DELETE FROM readings WHERE v > 10" -c "INSERT INTO readings VALUES (now(), -1)" >/dev/null
rm "$REPO/services/mosquitto/data/store/mosquitto.db" "$REPO/services/caddy/firmware/probe/app.bin"
echo "damaged: $(psql -c 'SELECT count(*), sum(v) FROM readings')"

RMX_REPO=$REPO RMX_ADMIN=root "$CI" restore "$WORK/backup.tar.gz"
after=$(psql -c "SELECT count(*), sum(v) FROM readings")
echo "after:  $after"
[[ $before == "$after" ]] || { echo "FAIL: data differs after restore" >&2; exit 1; }
[[ $(psql -c "SELECT count(*) FROM timescaledb_information.hypertables") == 1 ]] || { echo "FAIL: hypertable lost" >&2; exit 1; }
[[ $(cat "$REPO/services/mosquitto/data/store/mosquitto.db") == retained-message-store ]] || { echo "FAIL: mosquitto store not restored" >&2; exit 1; }
[[ $(cat "$REPO/services/caddy/firmware/probe/app.bin") == firmware-image ]] || { echo "FAIL: firmware not restored" >&2; exit 1; }
echo "OK: backup and restore round trip"
