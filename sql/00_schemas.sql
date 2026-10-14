SET client_min_messages = warning;
-- Schemas. Idempotent: safe to run any number of times.
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS reporting;

COMMENT ON SCHEMA raw       IS 'Source files loaded as-is (text columns, no cleaning).';
COMMENT ON SCHEMA reporting IS 'Cleaned loan-level mart and risk metrics (views only).';
