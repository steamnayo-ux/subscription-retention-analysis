-- 03_funnel.sql  (DuckDB)
-- 목적: 가입 -> 첫 결제 -> 1차 갱신 -> 2차 갱신 퍼널 (1% 샘플)
-- 전제: 00, 01 실행 완료 (members, sample_users, transactions_sample, params, sub_sequence)
-- 실행(프로젝트 루트): python python/run_sql.py sql/03_funnel.sql
-- 갱신 판정은 01_churn_definition.sql과 동일한 규칙을 사용 (N=30, 취소 거래 제외, 조기 갱신은 갱신으로 인정)

-- 0. 퍼널 파라미터 (00의 params는 건드리지 않음)
CREATE OR REPLACE VIEW funnel_params AS
SELECT 30                                   AS n_days,
       p.data_end                           AS data_end,
       (SELECT MIN(transaction_date)
          FROM transactions_sample
         WHERE is_cancel = 0)               AS tx_start      -- 거래 관측 시작일
FROM params p;

-- 1. 결제 건별 갱신 판정 (01의 churn_events와 같은 규칙에 결제 순번 rn을 추가)
--    renewed  : 다음 결제가 covered_until + N일 이내 (만료 전 조기 갱신 포함)
--    churned  : 다음 결제가 N일을 넘겨 발생(복귀 포함) 하거나, 다음 결제 없이 N일 이상 경과
--    censored : 다음 결제가 없고 아직 N일이 지나지 않아 판정 불가
CREATE OR REPLACE VIEW funnel_events AS
SELECT s.msno,
       ROW_NUMBER() OVER (PARTITION BY s.msno
                          ORDER BY s.transaction_date, s.membership_expire_date) AS rn,
       s.transaction_date AS tx_date,
       CASE
           WHEN s.next_tx_date IS NOT NULL
                AND date_diff('day', s.covered_until, s.next_tx_date) > f.n_days THEN 'churned'
           WHEN s.next_tx_date IS NULL
                AND s.covered_until + to_days(f.n_days) <= f.data_end            THEN 'churned'
           WHEN s.next_tx_date IS NULL                                           THEN 'censored'
           ELSE 'renewed'
       END AS status
FROM sub_sequence s
CROSS JOIN funnel_params f;

-- 2. 퍼널 분석 테이블: 샘플 회원 1명 = 1행
CREATE OR REPLACE TABLE funnel_user AS
SELECT m.msno,
       m.registration_date,
       (m.registration_date >= f.tx_start)                    AS reg_in_window,      -- 거래 관측 시작 이후 가입
       (m.registration_date + to_days(f.n_days) <= f.data_end) AS reg_30_observable, -- 가입 후 30일 관측 가능
       (e1.msno IS NOT NULL)                                  AS paid,               -- 관측 기간 내 (취소 아닌) 결제 이력 있음
       e1.tx_date                                             AS first_tx_date,
       (e1.tx_date <= m.registration_date + to_days(f.n_days)) AS paid_within_30d,
       e1.status                                              AS r1_status,
       e2.status                                              AS r2_status
FROM members m
JOIN sample_users u USING (msno)
CROSS JOIN funnel_params f
LEFT JOIN funnel_events e1 ON e1.msno = m.msno AND e1.rn = 1
LEFT JOIN funnel_events e2 ON e2.msno = m.msno AND e2.rn = 2;

-- 3. 퍼널 집계
--    users = 해당 단계 도달 인원, denom = 전환율 분모(판정 가능한 사람만), rate_pct = users / denom
CREATE OR REPLACE TABLE funnel_result AS
WITH cohorts AS (
    SELECT 'A. 전체 샘플 회원'         AS cohort, * FROM funnel_user
    UNION ALL
    SELECT 'B. 관측 기간 내 가입 회원' AS cohort, * FROM funnel_user WHERE reg_in_window
),
agg AS (
    SELECT cohort, 1 AS step_no, '샘플 회원' AS step_name,
           COUNT(*) AS users, NULL::BIGINT AS denom
    FROM cohorts GROUP BY cohort

    UNION ALL
    SELECT cohort, 2, '첫 결제 (관측 기간 내)',
           COUNT(*) FILTER (WHERE paid), COUNT(*)
    FROM cohorts GROUP BY cohort

    UNION ALL
    -- 가입 후 30일 이내 첫 결제: 가입 시점을 알 수 있는 B 코호트에서만 의미가 있음
    SELECT cohort, 3, '가입 후 30일 내 첫 결제 (B만)',
           COUNT(*) FILTER (WHERE paid_within_30d AND reg_30_observable),
           COUNT(*) FILTER (WHERE reg_30_observable)
    FROM cohorts WHERE cohort LIKE 'B.%' GROUP BY cohort

    UNION ALL
    SELECT cohort, 4, '1차 갱신 (판정 가능자 대비)',
           COUNT(*) FILTER (WHERE r1_status = 'renewed'),
           COUNT(*) FILTER (WHERE r1_status IN ('renewed', 'churned'))
    FROM cohorts GROUP BY cohort

    UNION ALL
    SELECT cohort, 5, '2차 갱신 (1차 갱신자 중 판정 가능자 대비)',
           COUNT(*) FILTER (WHERE r1_status = 'renewed' AND r2_status = 'renewed'),
           COUNT(*) FILTER (WHERE r1_status = 'renewed' AND r2_status IN ('renewed', 'churned'))
    FROM cohorts GROUP BY cohort
)
SELECT cohort, step_no, step_name, users, denom,
       ROUND(100.0 * users / NULLIF(denom, 0), 2) AS rate_pct
FROM agg
ORDER BY cohort, step_no;

SELECT * FROM funnel_result;

-- 4. 점검
-- (a) paid 사용자 수는 user_master(19,937)와 거의 같아야 함.
--     user_master는 취소 거래도 결제로 세므로, 취소 거래만 있는 사용자 수만큼 funnel이 작을 수 있음
-- (b) 1차 판정 분포 확인 (censored가 지나치게 많지 않은지)
SELECT 'funnel_user.paid' AS check_name, COUNT(*) FILTER (WHERE paid) AS n FROM funnel_user
UNION ALL SELECT 'user_master',  COUNT(*) FROM user_master
UNION ALL SELECT 'r1_renewed',   COUNT(*) FILTER (WHERE r1_status = 'renewed')  FROM funnel_user
UNION ALL SELECT 'r1_churned',   COUNT(*) FILTER (WHERE r1_status = 'churned')  FROM funnel_user
UNION ALL SELECT 'r1_censored',  COUNT(*) FILTER (WHERE r1_status = 'censored') FROM funnel_user;