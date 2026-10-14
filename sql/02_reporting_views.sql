-- Reporting layer: cleaned mart + risk metrics. Views only, CREATE OR REPLACE,
-- so the script is idempotent. Order matters: each view depends on the ones above.
--
-- Business rules (from the task):
--   portfolio   = SUM(principal_outstanding * FX rate on report_date), written-off loans excluded
--   PAR30/PAR90 = share of portfolio with days_past_due > 30 / > 90
--   NPL         = share of portfolio with days_past_due > 90 OR restructured
--   provisions  = amount * rate: NPL 50%; else DPD 31-90 10%; else (DPD 0-30) 1%
--   concentration = share of the 10 largest borrower groups (group_id) in portfolio
--
-- Assumptions (documented in README):
--   * "до 30 дней" includes 0 and exactly 30 days -> 1%; exactly 90 days -> 10% (not NPL).
--   * NPL has priority: a restructured loan gets 50% regardless of DPD.
--   * FX rate is taken on the report_date itself; if a date were missing, the last
--     earlier rate is used and fx_rate_date shows it (tests require exact date today).


-- 1. Loan-level snapshot: typed, exact duplicates removed, converted to KZT.
--    One row per (report_date, loan_id), INCLUDING written-off loans (flagged).
CREATE OR REPLACE VIEW reporting.v_loan_snapshot AS
WITH typed AS (
    -- SELECT DISTINCT removes exact duplicate rows (60 in the source file).
    -- Non-exact duplicates by key would survive here and fail tests on purpose.
    SELECT DISTINCT
        report_date::date                       AS report_date,
        trim(loan_id)                           AS loan_id,
        trim(borrower_id)                       AS borrower_id,
        trim(group_id)                          AS group_id,
        trim(sector)                            AS sector,
        trim(program)                           AS program,
        upper(trim(currency))                   AS currency,
        issue_date::date                        AS issue_date,
        maturity_date::date                     AS maturity_date,
        principal_outstanding::numeric(20, 2)   AS principal_outstanding,
        days_past_due::int                      AS days_past_due,
        restructured::int = 1                   AS is_restructured,
        written_off::int = 1                    AS is_written_off
    FROM raw.portfolio
),
fx AS (
    SELECT date::date AS rate_date, upper(trim(currency)) AS currency, rate_kzt::numeric(18, 6) AS rate_kzt
    FROM raw.fx
)
SELECT
    t.report_date,
    t.loan_id,
    t.borrower_id,
    t.group_id,
    t.sector,
    t.program,
    t.currency,
    t.issue_date,
    t.maturity_date,
    t.principal_outstanding,
    t.days_past_due,
    t.is_restructured,
    t.is_written_off,
    r.rate_date                                             AS fx_rate_date,
    r.rate_kzt                                              AS fx_rate,
    t.principal_outstanding * r.rate_kzt                    AS amount_kzt,
    CASE WHEN t.days_past_due = 0  THEN '0'
         WHEN t.days_past_due <= 30 THEN '1-30'
         WHEN t.days_past_due <= 90 THEN '31-90'
         ELSE '90+' END                                     AS dpd_bucket,
    t.days_past_due > 30                                    AS is_par30,
    t.days_past_due > 90                                    AS is_par90,
    (t.days_past_due > 90 OR t.is_restructured)             AS is_npl,
    CASE WHEN t.days_past_due > 90 OR t.is_restructured THEN 0.50
         WHEN t.days_past_due > 30                     THEN 0.10
         ELSE 0.01 END::numeric(4, 2)                       AS provision_rate,
    t.maturity_date < t.report_date                         AS is_past_maturity
FROM typed t
LEFT JOIN LATERAL (
    SELECT t.report_date AS rate_date, 1::numeric AS rate_kzt
    WHERE t.currency = 'KZT'
    UNION ALL
    (SELECT f.rate_date, f.rate_kzt
       FROM fx f
      WHERE t.currency <> 'KZT'
        AND f.currency = t.currency
        AND f.rate_date <= t.report_date
      ORDER BY f.rate_date DESC
      LIMIT 1)
) r ON true;

COMMENT ON VIEW reporting.v_loan_snapshot IS
    'Cleaned loan snapshot: typed, deduplicated, KZT amount at FX on report_date. Includes written-off loans (is_written_off).';


-- 2. Portfolio mart (source of the semantic model): active loans only,
--    with additive KZT measure columns so every metric is SUM(x) / SUM(amount_kzt).
CREATE OR REPLACE VIEW reporting.v_loan_portfolio AS
WITH g AS (
    SELECT report_date, group_id,
           dense_rank() OVER (PARTITION BY report_date ORDER BY SUM(amount_kzt) DESC) AS group_rank
    FROM reporting.v_loan_snapshot
    WHERE NOT is_written_off
    GROUP BY report_date, group_id
)
SELECT
    s.report_date,
    s.loan_id,
    s.borrower_id,
    s.group_id,
    s.sector,
    s.program,
    s.currency,
    s.dpd_bucket,
    s.days_past_due,
    s.is_restructured,
    s.is_npl,
    s.is_past_maturity,
    g.group_rank,
    g.group_rank <= 10                                   AS is_top10_group,
    s.principal_outstanding,
    s.fx_rate,
    s.amount_kzt,
    CASE WHEN s.is_par30 THEN s.amount_kzt ELSE 0 END    AS par30_kzt,
    CASE WHEN s.is_par90 THEN s.amount_kzt ELSE 0 END    AS par90_kzt,
    CASE WHEN s.is_npl   THEN s.amount_kzt ELSE 0 END    AS npl_kzt,
    s.provision_rate,
    s.amount_kzt * s.provision_rate                      AS provision_kzt,
    CASE WHEN g.group_rank <= 10 THEN s.amount_kzt ELSE 0 END AS top10_group_kzt
FROM reporting.v_loan_snapshot s
JOIN g ON g.report_date = s.report_date AND g.group_id = s.group_id
WHERE NOT s.is_written_off;

COMMENT ON VIEW reporting.v_loan_portfolio IS
    'Portfolio mart: one row per active (not written-off) loan per report_date with additive KZT risk measures.';


-- 3. Exposure by borrower group (for concentration).
CREATE OR REPLACE VIEW reporting.v_group_exposure AS
SELECT
    report_date,
    group_id,
    group_rank,
    COUNT(*)                                                        AS loans_cnt,
    SUM(amount_kzt)                                                 AS amount_kzt,
    SUM(amount_kzt) / SUM(SUM(amount_kzt)) OVER (PARTITION BY report_date) AS share_of_portfolio,
    SUM(npl_kzt)                                                    AS npl_kzt
FROM reporting.v_loan_portfolio
GROUP BY report_date, group_id, group_rank;


-- 4. Headline metrics: one row per report_date.
CREATE OR REPLACE VIEW reporting.v_portfolio_metrics AS
SELECT
    report_date,
    COUNT(*)                                AS loans_cnt,
    COUNT(DISTINCT borrower_id)             AS borrowers_cnt,
    SUM(amount_kzt)                         AS portfolio_kzt,
    SUM(par30_kzt)                          AS par30_kzt,
    SUM(par90_kzt)                          AS par90_kzt,
    SUM(npl_kzt)                            AS npl_kzt,
    SUM(provision_kzt)                      AS provisions_kzt,
    SUM(top10_group_kzt)                    AS top10_groups_kzt,
    SUM(par30_kzt)       / SUM(amount_kzt)  AS par30_ratio,
    SUM(par90_kzt)       / SUM(amount_kzt)  AS par90_ratio,
    SUM(npl_kzt)         / SUM(amount_kzt)  AS npl_ratio,
    SUM(provision_kzt)   / SUM(amount_kzt)  AS provision_coverage,
    SUM(provision_kzt)   / NULLIF(SUM(npl_kzt), 0) AS provisions_to_npl,
    SUM(top10_group_kzt) / SUM(amount_kzt)  AS top10_concentration
FROM reporting.v_loan_portfolio
GROUP BY report_date;


-- 5. Metrics in long format with change vs the base (first) snapshot, 01.09.2026.
--    change_abs for ratios is in fraction units (0.01 = 1 п.п.).
CREATE OR REPLACE VIEW reporting.v_portfolio_metrics_change AS
WITH long AS (
    SELECT m.report_date, x.sort_order, x.metric, x.label, x.unit, x.value
    FROM reporting.v_portfolio_metrics m
    CROSS JOIN LATERAL (VALUES
        (1,  'portfolio_kzt',       'Портфель, ₸',                   'kzt',   m.portfolio_kzt),
        (2,  'loans_cnt',           'Кредитов, шт.',                 'count', m.loans_cnt::numeric),
        (3,  'par30_ratio',         'PAR30',                         'ratio', m.par30_ratio),
        (4,  'par90_ratio',         'PAR90',                         'ratio', m.par90_ratio),
        (5,  'npl_ratio',           'NPL',                           'ratio', m.npl_ratio),
        (6,  'provisions_kzt',      'Провизии, ₸',                   'kzt',   m.provisions_kzt),
        (7,  'provision_coverage',  'Провизии / портфель',           'ratio', m.provision_coverage),
        (8,  'top10_concentration', 'Концентрация топ-10 групп',     'ratio', m.top10_concentration),
        (9,  'par30_kzt',           'PAR30, ₸',                      'kzt',   m.par30_kzt),
        (10, 'par90_kzt',           'PAR90, ₸',                      'kzt',   m.par90_kzt),
        (11, 'npl_kzt',             'NPL, ₸',                        'kzt',   m.npl_kzt),
        (12, 'top10_groups_kzt',    'Топ-10 групп, ₸',               'kzt',   m.top10_groups_kzt),
        (13, 'provisions_to_npl',   'Провизии / NPL',                'ratio', m.provisions_to_npl)
    ) AS x(sort_order, metric, label, unit, value)
),
base AS (
    SELECT DISTINCT ON (metric) metric, report_date AS base_date, value AS base_value
    FROM long
    ORDER BY metric, report_date
)
SELECT
    l.report_date,
    l.sort_order,
    l.metric,
    l.label,
    l.unit,
    l.value,
    b.base_date,
    b.base_value,
    l.value - b.base_value                                   AS change_abs,
    (l.value - b.base_value) / NULLIF(b.base_value, 0)       AS change_rel
FROM long l
JOIN base b USING (metric);


-- 6. Breakdowns by sector / program / currency, with change vs base date.
CREATE OR REPLACE VIEW reporting.v_portfolio_breakdown AS
WITH d AS (
    SELECT report_date, 'sector'::text AS dimension, sector AS dimension_value, amount_kzt, par30_kzt, par90_kzt, npl_kzt, provision_kzt
      FROM reporting.v_loan_portfolio
    UNION ALL
    SELECT report_date, 'program', program, amount_kzt, par30_kzt, par90_kzt, npl_kzt, provision_kzt
      FROM reporting.v_loan_portfolio
    UNION ALL
    SELECT report_date, 'currency', currency, amount_kzt, par30_kzt, par90_kzt, npl_kzt, provision_kzt
      FROM reporting.v_loan_portfolio
),
agg AS (
    SELECT
        report_date, dimension, dimension_value,
        COUNT(*)            AS loans_cnt,
        SUM(amount_kzt)     AS portfolio_kzt,
        SUM(par30_kzt)      AS par30_kzt,
        SUM(par90_kzt)      AS par90_kzt,
        SUM(npl_kzt)        AS npl_kzt,
        SUM(provision_kzt)  AS provisions_kzt
    FROM d
    GROUP BY report_date, dimension, dimension_value
),
r AS (
    SELECT
        a.*,
        portfolio_kzt / SUM(portfolio_kzt) OVER (PARTITION BY report_date, dimension) AS share_of_portfolio,
        par30_kzt      / portfolio_kzt AS par30_ratio,
        par90_kzt      / portfolio_kzt AS par90_ratio,
        npl_kzt        / portfolio_kzt AS npl_ratio,
        provisions_kzt / portfolio_kzt AS provision_coverage,
        MIN(report_date) OVER ()       AS base_date
    FROM agg a
)
SELECT
    r.*,
    r.portfolio_kzt - b.portfolio_kzt  AS portfolio_change_kzt,
    r.npl_ratio     - b.npl_ratio      AS npl_ratio_change,
    r.par30_ratio   - b.par30_ratio    AS par30_ratio_change
FROM r
LEFT JOIN r b
       ON b.report_date = r.base_date
      AND b.dimension = r.dimension
      AND b.dimension_value = r.dimension_value;


-- 7. DPD bucket migration between consecutive snapshots (roll rates).
--    'written_off' is a separate state; amount is at the earlier date.
CREATE OR REPLACE VIEW reporting.v_dpd_migration AS
WITH s AS (
    SELECT report_date, loan_id, amount_kzt,
           CASE WHEN is_written_off THEN 'written_off'
                WHEN is_restructured AND days_past_due <= 90 THEN 'restructured'
                ELSE dpd_bucket END AS state,
           LEAD(report_date) OVER w AS next_date,
           LEAD(CASE WHEN is_written_off THEN 'written_off'
                     WHEN is_restructured AND days_past_due <= 90 THEN 'restructured'
                     ELSE dpd_bucket END) OVER w AS next_state
    FROM reporting.v_loan_snapshot
    WINDOW w AS (PARTITION BY loan_id ORDER BY report_date)
)
SELECT
    report_date AS from_date,
    next_date   AS to_date,
    state       AS from_state,
    next_state  AS to_state,
    COUNT(*)        AS loans_cnt,
    SUM(amount_kzt) AS amount_kzt_from
FROM s
WHERE next_date IS NOT NULL
GROUP BY report_date, next_date, state, next_state;


-- 8. Portfolio bridge base -> next snapshot: why did the portfolio change?
--    Same loan universe on both dates (no new issuance in the data), so:
--    delta = repayments (at base FX) + FX revaluation + write-offs + write-off reversals.
CREATE OR REPLACE VIEW reporting.v_portfolio_bridge AS
WITH seq AS (
    SELECT loan_id, report_date, is_written_off, amount_kzt, fx_rate,
           LEAD(report_date)           OVER w AS next_date,
           LEAD(is_written_off)        OVER w AS next_wo,
           LEAD(amount_kzt)            OVER w AS next_amt,
           LEAD(principal_outstanding) OVER w AS next_principal
    FROM reporting.v_loan_snapshot
    WINDOW w AS (PARTITION BY loan_id ORDER BY report_date)
),
pair AS (
    SELECT loan_id,
           report_date AS d0, next_date AS d1,
           is_written_off AS wo0, next_wo AS wo1,
           amount_kzt AS amt0, next_amt AS amt1,
           next_principal * fx_rate AS amt1_at_fx0
    FROM seq
    WHERE next_date IS NOT NULL
),
c AS (
    SELECT d0, d1,
        SUM(CASE WHEN NOT wo0 THEN amt0 ELSE 0 END)                       AS portfolio_start,
        SUM(CASE WHEN NOT wo0 AND NOT wo1 THEN amt1_at_fx0 - amt0 ELSE 0 END) AS repayments,
        SUM(CASE WHEN NOT wo0 AND NOT wo1 THEN amt1 - amt1_at_fx0 ELSE 0 END) AS fx_revaluation,
        SUM(CASE WHEN NOT wo0 AND wo1 THEN -amt0 ELSE 0 END)              AS new_write_offs,
        SUM(CASE WHEN wo0 AND NOT wo1 THEN amt1 ELSE 0 END)               AS write_off_reversals,
        SUM(CASE WHEN NOT wo1 THEN amt1 ELSE 0 END)                       AS portfolio_end
    FROM pair
    GROUP BY d0, d1
)
SELECT c.d0 AS from_date, c.d1 AS to_date, x.step_order, x.step, x.label, x.amount_kzt
FROM c
CROSS JOIN LATERAL (VALUES
    (1, 'portfolio_start',     'Портфель на начало',          c.portfolio_start),
    (2, 'repayments',          'Погашения',                   c.repayments),
    (3, 'fx_revaluation',      'Переоценка USD',              c.fx_revaluation),
    (4, 'new_write_offs',      'Новые списания',              c.new_write_offs),
    (5, 'write_off_reversals', 'Возврат из списания',         c.write_off_reversals),
    (6, 'portfolio_end',       'Портфель на конец',           c.portfolio_end)
) AS x(step_order, step, label, amount_kzt);


-- 9. Data-quality summary: what cleaning did and what looks suspicious.
CREATE OR REPLACE VIEW reporting.v_data_quality AS
SELECT 'raw_rows' AS check_name, 'Строк в raw.portfolio' AS description,
       (SELECT COUNT(*) FROM raw.portfolio)::numeric AS value
UNION ALL
SELECT 'exact_duplicates_removed', 'Удалено полных дублей строк',
       (SELECT COUNT(*) FROM raw.portfolio) - (SELECT COUNT(*) FROM reporting.v_loan_snapshot)
UNION ALL
SELECT 'written_off_excluded', 'Списанных кредитов исключено (обе даты)',
       (SELECT COUNT(*) FROM reporting.v_loan_snapshot WHERE is_written_off)
UNION ALL
SELECT 'write_off_reversals', 'Кредитов: списан на 01.09, активен на 01.10',
       (SELECT COALESCE(SUM(loans_cnt), 0) FROM reporting.v_dpd_migration WHERE from_state = 'written_off' AND to_state <> 'written_off')
UNION ALL
SELECT 'past_maturity_active', 'Активных кредитов с истёкшим сроком (обе даты)',
       (SELECT COUNT(*) FROM reporting.v_loan_portfolio WHERE is_past_maturity)
UNION ALL
SELECT 'fx_not_on_report_date', 'Кредитов с курсом не на дату среза',
       (SELECT COUNT(*) FROM reporting.v_loan_snapshot WHERE fx_rate_date <> report_date OR fx_rate IS NULL);
