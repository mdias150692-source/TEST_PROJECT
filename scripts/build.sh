#!/usr/bin/env bash
# Full idempotent build: schemas -> raw load -> reporting views -> tests -> dashboard data.
# Safe to run repeatedly: raw tables are reloaded as TRUNCATE + COPY in one transaction,
# views are CREATE OR REPLACE.
#
# Connection comes from standard libpq env vars (PGHOST, PGPORT, PGUSER, PGDATABASE,
# PGPASSWORD), read from .env if present. Never hard-code passwords here.
#
# Uses local psql by default. With Docker and no local psql:
#   PSQL="docker exec -i -e PGPASSWORD risk-pg psql -U postgres -d risk" ./scripts/build.sh
# All SQL and CSV go through stdin, so no volume mounts are needed.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
    set -a; . ./.env; set +a
fi
export PGCLIENTENCODING=UTF8

PSQL_CMD=${PSQL:-psql}
psql_run() { $PSQL_CMD -X -q -v ON_ERROR_STOP=1 "$@"; }

echo "==> schemas & raw tables"
psql_run < sql/00_schemas.sql
psql_run < sql/01_raw_tables.sql

echo "==> load raw.portfolio, raw.fx (TRUNCATE + COPY, single transaction)"
psql_run -1 -c "TRUNCATE raw.portfolio" \
    -c "\copy raw.portfolio (report_date, loan_id, borrower_id, group_id, sector, program, currency, issue_date, maturity_date, principal_outstanding, days_past_due, restructured, written_off) FROM pstdin WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')" \
    < data/portfolio.csv
psql_run -1 -c "TRUNCATE raw.fx" \
    -c "\copy raw.fx (date, currency, rate_kzt) FROM pstdin WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')" \
    < data/fx.csv

echo "==> reporting views"
psql_run < sql/02_reporting_views.sql

echo "==> tests"
psql_run < sql/90_tests.sql

echo "==> export dashboard data (JSON) and metrics CSV"
mkdir -p dashboard/data
export_json() {  # $1 = view, $2 = order by, $3 = output file, $4 = optional filter
    psql_run -A -t -c "SELECT COALESCE(json_agg(t ORDER BY $2), '[]') FROM reporting.$1 t WHERE ${4:-true}" > "dashboard/data/$3"
}
export_json v_portfolio_metrics_change "report_date, sort_order"           metrics.json
export_json v_portfolio_breakdown      "report_date, dimension, portfolio_kzt DESC" breakdown.json
export_json v_group_exposure           "report_date, group_rank"           groups.json "group_rank <= 15"
export_json v_dpd_migration            "from_date, from_state, to_state"   migration.json
export_json v_portfolio_bridge         "from_date, step_order"             bridge.json
export_json v_data_quality             "check_name"                        data_quality.json
psql_run -c "\copy (SELECT * FROM reporting.v_portfolio_metrics ORDER BY report_date) TO pstdout WITH (FORMAT csv, HEADER true)" \
    > checks/sql_metrics.csv

echo "==> done"
