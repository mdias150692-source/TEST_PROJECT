SET client_min_messages = warning;
-- Raw landing tables. Columns are TEXT on purpose: raw keeps the file exactly
-- as delivered, all typing/cleaning happens in reporting.* views.
-- Data is (re)loaded by scripts/build.sh as TRUNCATE + COPY in one transaction,
-- so re-running never duplicates rows.

CREATE TABLE IF NOT EXISTS raw.portfolio (
    report_date           text,
    loan_id               text,
    borrower_id           text,
    group_id              text,
    sector                text,
    program               text,
    currency              text,
    issue_date            text,
    maturity_date         text,
    principal_outstanding text,
    days_past_due         text,
    restructured          text,
    written_off           text,
    _loaded_at            timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw.fx (
    date       text,
    currency   text,
    rate_kzt   text,
    _loaded_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE raw.portfolio IS 'portfolio.csv: monthly loan snapshots, principal_outstanding in loan currency.';
COMMENT ON TABLE raw.fx        IS 'fx.csv: daily FX rates to KZT.';
