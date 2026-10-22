-- 04_cohort_retention.sql  (DuckDB)
-- 목적: 첫 결제월 코호트별 구독 유지율 (체험 / 무료 시작 / 유료 시작 분리)
-- 전제: 01(sub_sequence, params), 03(funnel_user) 실행 완료
--
-- 정의
--   모집단   : funnel_user.reg_in_window = TRUE (퍼널 B 코호트) 중, 취소 제외 거래가 있는 사용자
--              -> 03b와 같은 모집단이므로 합계가 퍼널 첫 결제자 수(9,097명)와 같아야 함
--   d0       : 첫 결제일 (취소 제외 첫 거래의 transaction_date, sub_sequence와 같은 기준)
--   cohort_month : d0의 월
--   첫 거래 선택 : 거래일, 만료일이 같은 거래가 여럿이면 결제금액이 큰 거래를 첫 거래로 봄
--              (같은 날 같은 만료일에 0원 행과 99원 행이 함께 찍힌 사용자 41명 확인.
--               0원 행은 정가 149 기준의 보조 행으로 보이고, 실결제는 99원 행으로 추정.
--               정렬 기준이 없으면 어느 행이 뽑힐지 실행마다 달라질 수 있어 고정함)
--   segment  : 첫 결제 기준
--                trial      = 첫 플랜 7일 (무료 체험 추정, 03c와 같은 기준)
--                free_start = 7일 플랜이 아니면서 첫 결제금액 0원 (쿠폰·프로모션 시작 추정)
--                paid       = 7일 플랜이 아니면서 첫 결제금액 > 0원
--              (04e 결과: 0원 시작자는 갱신 행동이 달라 paid에서 분리)
--   month_k  : 첫 결제일 + k개월 시점 (달력 월). 30일 단위가 아님
--   checkpoint : k=0 이면 d0, k>=1 이면 d0 + k개월 + buffer_days
--                (04d 결과: 30일 플랜의 만료일이 달력 월 기준으로 d0+31~33일에 찍히므로,
--                 buffer 없이 d0+30일로 보면 갱신하지 않은 사용자도 1개월차 유지로 잡힘.
--                 기본값 buffer_days = 7: 만료 후 7일 이내 늦은 갱신은 유지로 봄)
--   retained : checkpoint 이전(당일 포함)까지의 covered_until이 checkpoint보다 큼 (엄격한 >)
--   censoring: checkpoint가 데이터 종료일(params.data_end)을 넘는 (사용자, month_k)는 제외
--              -> 분모(users)가 month_k마다 달라질 수 있음
-- 주의: 구독 유지(결제 기준)가 주 지표. 활동 유지(청취)는 별도 분석.
--       퍼널 1차 갱신률(만료 후 30일 안에 갱신하면 갱신)과는 다른 지표임.
--       cohort_user_month, cohort_retention에는 buffer_days 열이 있음 (0, 3, 7, 14).
--       집계할 때는 buffer_days = 7 만 쓸 것.

-- 1. 코호트 기준 테이블
CREATE OR REPLACE TABLE cohort_base AS
WITH first_tx AS (
    SELECT msno,
           transaction_date AS d0,
           payment_plan_days,
           actual_amount_paid
    FROM (
        SELECT msno, transaction_date, payment_plan_days, actual_amount_paid,
               ROW_NUMBER() OVER (PARTITION BY msno
                                  ORDER BY transaction_date,
                                           membership_expire_date,
                                           actual_amount_paid DESC,
                                           payment_plan_days DESC) AS rn
        FROM transactions_sample
        WHERE is_cancel = 0
    )
    WHERE rn = 1
)
SELECT f.msno,
       f.d0,
       date_trunc('month', f.d0)::DATE AS cohort_month,
       CASE WHEN f.payment_plan_days = 7   THEN 'trial'
            WHEN f.actual_amount_paid = 0  THEN 'free_start'
            ELSE 'paid' END AS segment
FROM first_tx f
JOIN funnel_user fu USING (msno)
WHERE fu.reg_in_window;

-- 2. 날짜별 covered_until (같은 날 거래가 여러 건이면 누적 최댓값만 남김)
CREATE OR REPLACE TABLE sub_daily AS
SELECT msno, transaction_date, MAX(covered_until) AS covered_until
FROM sub_sequence
GROUP BY msno, transaction_date;

-- 3. 사용자 x month_k x buffer_days 격자 (관측 가능한 시점만) + 시점별 구독 유지 여부
CREATE OR REPLACE TABLE cohort_user_month AS
WITH raw AS (
    SELECT c.msno, c.cohort_month, c.segment, b.buffer_days, g.month_k,
           CASE WHEN g.month_k = 0 THEN c.d0
                ELSE (c.d0 + to_months(CAST(g.month_k AS INTEGER)))::DATE + b.buffer_days
           END AS checkpoint
    FROM cohort_base c
    CROSS JOIN generate_series(0, 12) AS g(month_k)
    CROSS JOIN (VALUES (0), (3), (7), (14)) AS b(buffer_days)
),
grid AS (
    SELECT r.*
    FROM raw r
    CROSS JOIN params p
    WHERE r.checkpoint <= p.data_end
)
SELECT gr.msno, gr.cohort_month, gr.segment, gr.buffer_days, gr.month_k, gr.checkpoint,
       COALESCE(sd.covered_until > gr.checkpoint, FALSE) AS retained
FROM grid gr
ASOF LEFT JOIN sub_daily sd
  ON gr.msno = sd.msno
 AND gr.checkpoint >= sd.transaction_date;

-- 4. 코호트 x 세그먼트 x month_k x buffer_days 유지율 (노트북 히트맵용)
CREATE OR REPLACE TABLE cohort_retention AS
SELECT cohort_month, segment, buffer_days, month_k,
       COUNT(*)                                    AS users,
       COUNT(*) FILTER (WHERE retained)            AS retained_users,
       ROUND(100.0 * COUNT(*) FILTER (WHERE retained) / COUNT(*), 2) AS retention_pct
FROM cohort_user_month
GROUP BY ALL;

-- ===== 확인용 표 1: 코호트 규모 (마지막 행 = 전체 합계) =====
SELECT cohort_month,
       COUNT(*) FILTER (WHERE segment = 'trial')      AS trial_users,
       COUNT(*) FILTER (WHERE segment = 'free_start') AS free_start_users,
       COUNT(*) FILTER (WHERE segment = 'paid')       AS paid_users,
       COUNT(*)                                       AS total_users
FROM cohort_base
GROUP BY ROLLUP (cohort_month)
ORDER BY cohort_month NULLS LAST;

-- ===== 확인용 표 2: month_k별 전체 코호트 합산 유지율 (buffer_days = 7) =====
SELECT month_k,
       SUM(users) FILTER (WHERE segment = 'trial') AS trial_n,
       ROUND(100.0 * SUM(retained_users) FILTER (WHERE segment = 'trial')
             / NULLIF(SUM(users) FILTER (WHERE segment = 'trial'), 0), 2)      AS trial_pct,
       SUM(users) FILTER (WHERE segment = 'free_start') AS free_n,
       ROUND(100.0 * SUM(retained_users) FILTER (WHERE segment = 'free_start')
             / NULLIF(SUM(users) FILTER (WHERE segment = 'free_start'), 0), 2) AS free_pct,
       SUM(users) FILTER (WHERE segment = 'paid')  AS paid_n,
       ROUND(100.0 * SUM(retained_users) FILTER (WHERE segment = 'paid')
             / NULLIF(SUM(users) FILTER (WHERE segment = 'paid'), 0), 2)       AS paid_pct
FROM cohort_retention
WHERE buffer_days = 7
GROUP BY month_k
ORDER BY month_k;

-- ===== 확인용 표 3: buffer_days 민감도 (month_k = 1, 3, 6) =====
SELECT month_k, buffer_days,
       ROUND(100.0 * SUM(retained_users) FILTER (WHERE segment = 'trial')
             / NULLIF(SUM(users) FILTER (WHERE segment = 'trial'), 0), 2)      AS trial_pct,
       ROUND(100.0 * SUM(retained_users) FILTER (WHERE segment = 'free_start')
             / NULLIF(SUM(users) FILTER (WHERE segment = 'free_start'), 0), 2) AS free_pct,
       ROUND(100.0 * SUM(retained_users) FILTER (WHERE segment = 'paid')
             / NULLIF(SUM(users) FILTER (WHERE segment = 'paid'), 0), 2)       AS paid_pct
FROM cohort_retention
WHERE month_k IN (1, 3, 6)
GROUP BY month_k, buffer_days
ORDER BY month_k, buffer_days;
