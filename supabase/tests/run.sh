#!/usr/bin/env bash
# Runs every migration + test against a throwaway local Postgres 16 with Supabase-style stubs.
# Usage: supabase/tests/run.sh   (needs postgresql-16 binaries; PGBIN overrides the path)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
D="$(mktemp -d)"; PORT="${PGPORT_TEST:-5544}"
asdb() { if [ "$(id -u)" = 0 ]; then su postgres -c "$1"; else bash -c "$1"; fi; }
[ "$(id -u)" = 0 ] && chown postgres "$D"
trap 'asdb "$PGBIN/pg_ctl -D $D/db stop -m immediate >/dev/null 2>&1"; rm -rf "$D"' EXIT
asdb "$PGBIN/initdb -D $D/db -A trust >/dev/null" || exit 1
asdb "$PGBIN/pg_ctl -D $D/db -o '-p $PORT -k $D' -l $D/log start >/dev/null" || exit 1; sleep 2
P() { psql -h "$D" -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -q postgres "$@"; }
P -f "$HERE/_stubs.sql" || exit 1
for f in "$ROOT"/supabase/migrations/*.sql; do echo "migrate $(basename "$f")"; P -f "$f" >/dev/null || exit 1; done
P -f "$HERE/_lib.sql" || exit 1
P -f "$HERE/_fixtures.sql" || exit 1
fail=0
for f in "$HERE"/[0-9]*.sql; do
  echo "== $(basename "$f")"
  P -f "$f" 2>&1 | grep -E "NOT OK|ERROR" ; [ "${PIPESTATUS[0]}" = 0 ] || fail=1
done
P -t -c "select 'passed: '||count(*) filter (where ok)||'  failed: '||count(*) filter (where not ok) from t.results" | tee "$D/sum"
grep -q "failed: 0" "$D/sum" && [ "$fail" = 0 ]
