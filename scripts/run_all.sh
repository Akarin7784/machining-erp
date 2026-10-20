#!/usr/bin/env bash
# 从零建库 → 迁移 → 函数 → 参数种子 → 端到端剧本(DO 块断言) → pgTAP 测试(pg_prove)
# 用法：
#   已有 PostgreSQL：PGHOST=... PGPORT=... PGUSER=postgres scripts/run_all.sh
#   未设置 PGHOST：若找到 initdb，则在 /tmp 起一个临时实例跑完即停
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${ERP_DB:-machining_erp}
TEMP_CLUSTER=""
if [[ -z "${PGHOST:-}" ]]; then
  PGBIN=${PGBIN:-$(pg_config --bindir 2>/dev/null || ls -d /usr/lib/postgresql/*/bin 2>/dev/null | tail -1)}
  export PATH="$PGBIN:$PATH"
  TEMP_CLUSTER=$(mktemp -d /tmp/erp_pg.XXXX)
  initdb -D "$TEMP_CLUSTER" -U postgres -A trust -E UTF8 --locale=C.UTF-8 >/dev/null
  pg_ctl -D "$TEMP_CLUSTER" -o "-p ${PGPORT:-5499} -k /tmp -c listen_addresses=localhost" -l "$TEMP_CLUSTER/log" start -w >/dev/null
  export PGHOST=localhost PGPORT=${PGPORT:-5499} PGUSER=postgres
  trap 'pg_ctl -D "$TEMP_CLUSTER" stop -m fast >/dev/null; rm -rf "$TEMP_CLUSTER"' EXIT
fi
export PGUSER=${PGUSER:-postgres}
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")

echo "== 1. 重建数据库 $DB"
psql -X -q -d postgres -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB"
echo "== 2. 迁移 (db/migrations)"
for f in db/migrations/*.sql; do echo "   $f"; "${PSQL[@]}" -f "$f"; done
echo "== 3. 函数 (db/functions)"
for f in db/functions/*.sql; do echo "   $f"; "${PSQL[@]}" -f "$f"; done
echo "== 4. 参数种子 (db/seed)"
for f in db/seed/*.sql; do echo "   $f"; "${PSQL[@]}" -f "$f"; done
echo "== 5. 端到端剧本 (db/scenarios)"
for f in db/scenarios/*.sql; do echo "   $f"; "${PSQL[@]}" -o /dev/null -f "$f"; done
echo "== 6. pgTAP 测试 (db/tests)"
"${PSQL[@]}" -c "CREATE EXTENSION IF NOT EXISTS pgtap"
if command -v pg_prove >/dev/null; then
  pg_prove -d "$DB" db/tests/*.sql
else
  prove -v --exec "psql -X -q -At -v ON_ERROR_STOP=1 -d $DB -f" db/tests/*.sql
fi
echo "== 统计"
"${PSQL[@]}" -At -c "SELECT 'tables='||count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'" \
  -c "SELECT 'views='||count(*) FROM information_schema.views WHERE table_schema='public'" \
  -c "SELECT 'functions='||count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname ~ '^(fn_|trg_)'"
if [[ "${GEN_DOCS:-0}" == "1" ]]; then ERP_DB=$DB python3 scripts/gen_docs.py; fi
echo "ALL PASSED"
