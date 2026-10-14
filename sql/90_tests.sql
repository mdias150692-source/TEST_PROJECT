-- Data & logic tests. Each block raises an exception on failure, so with
-- ON_ERROR_STOP=1 the build stops. Read-only: changes nothing in the database.

DO $$
DECLARE n bigint; x numeric;
BEGIN
    -- 1. raw loaded
    SELECT COUNT(*) INTO n FROM raw.portfolio;
    IF n = 0 THEN RAISE EXCEPTION 'raw.portfolio is empty'; END IF;
    SELECT COUNT(*) INTO n FROM raw.fx;
    IF n = 0 THEN RAISE EXCEPTION 'raw.fx is empty'; END IF;

    -- 2. snapshot is unique by (report_date, loan_id) => no non-exact duplicates
    SELECT COUNT(*) INTO n FROM (
        SELECT 1 FROM reporting.v_loan_snapshot GROUP BY report_date, loan_id HAVING COUNT(*) > 1) t;
    IF n > 0 THEN RAISE EXCEPTION 'v_loan_snapshot: % duplicate (report_date, loan_id) keys', n; END IF;

    -- 3. snapshot = distinct raw rows (nothing lost besides exact duplicates)
    SELECT (SELECT COUNT(*) FROM (SELECT DISTINCT report_date, loan_id, borrower_id, group_id, sector, program, currency,
                                          issue_date, maturity_date, principal_outstanding, days_past_due,
                                          restructured, written_off FROM raw.portfolio) d)
         - (SELECT COUNT(*) FROM reporting.v_loan_snapshot) INTO n;
    IF n <> 0 THEN RAISE EXCEPTION 'snapshot row count differs from distinct raw rows by %', n; END IF;

    -- 4. FX: every loan converted, rate taken exactly on report_date
    SELECT COUNT(*) INTO n FROM reporting.v_loan_snapshot
     WHERE fx_rate IS NULL OR amount_kzt IS NULL OR fx_rate_date <> report_date;
    IF n > 0 THEN RAISE EXCEPTION '% loans without FX rate on report_date', n; END IF;

    -- 5. FX table unique by (date, currency)
    SELECT COUNT(*) INTO n FROM (SELECT 1 FROM raw.fx GROUP BY date, currency HAVING COUNT(*) > 1) t;
    IF n > 0 THEN RAISE EXCEPTION 'raw.fx has % duplicate (date, currency)', n; END IF;

    -- 6. sane values; flags strictly 0/1 (a '2' or 'Y' would otherwise silently become false)
    SELECT COUNT(*) INTO n FROM raw.portfolio
     WHERE trim(restructured) NOT IN ('0', '1') OR trim(written_off) NOT IN ('0', '1');
    IF n > 0 THEN RAISE EXCEPTION '% rows with restructured/written_off not in (0, 1)', n; END IF;
    SELECT COUNT(*) INTO n FROM reporting.v_loan_snapshot
     WHERE principal_outstanding < 0 OR days_past_due < 0 OR currency NOT IN ('KZT', 'USD');
    IF n > 0 THEN RAISE EXCEPTION '% rows with negative amount/DPD or unknown currency', n; END IF;

    -- 7. written-off loans never enter the portfolio mart
    SELECT COUNT(*) INTO n FROM reporting.v_loan_portfolio p
      JOIN reporting.v_loan_snapshot s USING (report_date, loan_id) WHERE s.is_written_off;
    IF n > 0 THEN RAISE EXCEPTION 'written-off loans found in v_loan_portfolio'; END IF;

    -- 8. metric ordering invariants
    SELECT COUNT(*) INTO n FROM reporting.v_portfolio_metrics
     WHERE NOT (par90_kzt <= par30_kzt AND par30_kzt <= portfolio_kzt
                AND par90_kzt <= npl_kzt AND npl_kzt <= portfolio_kzt
                AND provisions_kzt BETWEEN 0.01 * portfolio_kzt AND 0.50 * portfolio_kzt
                AND top10_groups_kzt <= portfolio_kzt);
    IF n > 0 THEN RAISE EXCEPTION 'metric invariants violated on % dates', n; END IF;

    -- 9. breakdowns add up to the total for each dimension
    SELECT COUNT(*) INTO n FROM (
        SELECT b.report_date, b.dimension, SUM(b.portfolio_kzt) s, SUM(b.provisions_kzt) p, SUM(b.npl_kzt) npl
          FROM reporting.v_portfolio_breakdown b GROUP BY 1, 2) b
      JOIN reporting.v_portfolio_metrics m USING (report_date)
     WHERE abs(b.s - m.portfolio_kzt) > 0.01 OR abs(b.p - m.provisions_kzt) > 0.01 OR abs(b.npl - m.npl_kzt) > 0.01;
    IF n > 0 THEN RAISE EXCEPTION 'breakdown totals differ from metrics (% cases)', n; END IF;

    -- 10. concentration uses exactly 10 groups per date (no ties at the cut-off)
    SELECT COUNT(*) INTO n FROM (
        SELECT report_date FROM reporting.v_group_exposure WHERE group_rank <= 10
         GROUP BY report_date HAVING COUNT(*) <> 10) t;
    IF n > 0 THEN RAISE EXCEPTION 'top-10 group set is not exactly 10 groups'; END IF;

    -- 11. bridge reconciles: start + steps = end, and end = metrics of next date
    SELECT MAX(abs(
             (SELECT SUM(amount_kzt) FROM reporting.v_portfolio_bridge b2
               WHERE b2.from_date = b.from_date AND b2.step_order BETWEEN 1 AND 5)
           - b.amount_kzt)) INTO x
      FROM reporting.v_portfolio_bridge b WHERE b.step = 'portfolio_end';
    IF x > 0.01 THEN RAISE EXCEPTION 'portfolio bridge does not reconcile (diff %)', x; END IF;
    SELECT COUNT(*) INTO n FROM reporting.v_portfolio_bridge b
      JOIN reporting.v_portfolio_metrics m ON m.report_date = b.to_date
     WHERE b.step = 'portfolio_end' AND abs(b.amount_kzt - m.portfolio_kzt) > 0.01;
    IF n > 0 THEN RAISE EXCEPTION 'bridge end differs from portfolio metric'; END IF;

    -- 12. migration covers all loans present on both dates
    SELECT (SELECT SUM(loans_cnt) FROM reporting.v_dpd_migration)
         - (SELECT COUNT(*) - COUNT(DISTINCT loan_id) FROM reporting.v_loan_snapshot) INTO n;
    IF n <> 0 THEN RAISE EXCEPTION 'migration matrix misses % loans', n; END IF;

    -- 13. base-date changes are zero on the base date
    SELECT COUNT(*) INTO n FROM reporting.v_portfolio_metrics_change WHERE report_date = base_date AND change_abs <> 0;
    IF n > 0 THEN RAISE EXCEPTION 'non-zero change on base date'; END IF;

    RAISE NOTICE 'All reporting tests passed';
END $$;
