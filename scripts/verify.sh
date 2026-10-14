#!/usr/bin/env bash
# Independent verification after scripts/build.sh:
#   1. pure-Python recomputation of all metrics from the CSV files, compared with the SQL export;
#   2. semantic YAML models validated against the live views and reconciled with the metrics view.
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHON=${PYTHON:-$(command -v python3 || command -v python)}
export PYTHONIOENCODING=utf-8

echo "==> reference recomputation vs reporting.v_portfolio_metrics"
"$PYTHON" -I checks/reference_metrics.py --compare checks/sql_metrics.csv | tail -n 1

echo "==> semantic models"
"$PYTHON" -I checks/validate_semantic.py
