-- 01_churn_definition.sql  (DuckDB)
-- 목적: "구독 만료 후 N일 안에 재결제가 없으면 이탈"로 직접 정의하고, N을 바꿔 결과가 유지되는지 확인
-- 전제: 00_load_and_sample.sql 실행 완료
--
-- 정의
--   covered_until : 해당 거래까지 누적해서 구독이 커버되는 마지막 날 (만료일의 누적 최댓값)
--   renewed       : 다음 결제가 covered_until 이후 N일 이내에 발생
--   churn_then_return : N일을 넘겨 다시 결제 (한 번 이탈했다가 복귀)
--   churn         : 이후 결제가 없고, 데이터 종료일까지 N일 이상 지남
--   censored      : 이후 결제가 없지만 아직 N일이 지나지 않아 판단 불가
--                   (만료 건 기준 이탈률에서는 제외, 사용자 기준 이탈률에서는 활동 중으로 취급)
-- 결정 사항: is_cancel = 1 거래는 갱신으로 보지 않고 제외했습니다. 이 가정은 README에 적고 검증하세요.

-- 1. 사용자별 구독 거래 시퀀스
CREATE OR REPLACE TABLE sub_sequence AS
SELECT msno,
       transaction_date,
       membership_expire_date,
       MAX(membership_expire_date) OVER (
           PARTITION BY msno
           ORDER BY transaction_date, membership_expire_date
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS covered_until,
       LEAD(transaction_date) OVER (
           PARTITION BY msno
           ORDER BY transaction_date, membership_expire_date
       ) AS next_tx_date
FROM transactions_sample
WHERE is_cancel = 0;

-- 2. 이탈 이벤트 (N = 15 / 30 / 45일 민감도)
CREATE OR REPLACE TABLE churn_events AS
SELECT s.msno,
       n.n_days,
       s.covered_until AS expire_date,
       s.next_tx_date,
       CASE
           WHEN s.next_tx_date IS NOT NULL
                AND date_diff('day', s.covered_until, s.next_tx_date) > n.n_days
               THEN 'churn_then_return'
           WHEN s.next_tx_date IS NULL
                AND s.covered_until + to_days(n.n_days) <= p.data_end
               THEN 'churn'
           WHEN s.next_tx_date IS NULL
               THEN 'censored'
           ELSE 'renewed'
       END AS outcome
FROM sub_sequence s
CROSS JOIN (VALUES (15), (30), (45)) AS n(n_days)
CROSS JOIN params p;

-- 3. 사용자 단위 요약
CREATE OR REPLACE TABLE user_churn AS
SELECT msno,
       n_days,
       BOOL_OR(outcome IN ('churn', 'churn_then_return'))        AS ever_churned,
       BOOL_OR(outcome = 'churn')                                AS churned_final,
       BOOL_OR(outcome = 'censored')                             AS is_censored,
       COUNT(*) FILTER (WHERE outcome = 'churn_then_return')     AS n_returns,
       MIN(expire_date) FILTER (WHERE outcome IN ('churn', 'churn_then_return')) AS first_churn_expire_date
FROM churn_events
GROUP BY msno, n_days;

-- 4. 민감도: N에 따라 이탈률이 얼마나 변하는가
-- (a) 만료 건 기준: 판정 가능한(censored 제외) 만료 건 중 이탈 비율
SELECT n_days,
       COUNT(*) FILTER (WHERE outcome <> 'censored') AS decided_events,
       ROUND(AVG((outcome IN ('churn', 'churn_then_return'))::INT)
             FILTER (WHERE outcome <> 'censored'), 4) AS churn_event_rate
FROM churn_events
GROUP BY n_days
ORDER BY n_days;

-- (b) 사용자 기준: censored(아직 판정 불가)는 활동 중으로 보고 전체 사용자 대비 비율
--     주의: censored 사용자를 빼고 계산하면 남는 사용자는 모두 이탈이라 항상 100%가 됨
SELECT n_days,
       COUNT(*)                          AS users,
       ROUND(AVG(ever_churned::INT), 4)  AS ever_churn_rate,
       ROUND(AVG(churned_final::INT), 4) AS final_churn_rate
FROM user_churn
GROUP BY n_days
ORDER BY n_days;

-- 5. 공식 라벨(is_churn)과의 일치도 검증 (train.csv = 2017-02 만료 사용자 가정, 기간은 확인 필요)
WITH feb AS (
    SELECT msno, outcome,
           ROW_NUMBER() OVER (PARTITION BY msno ORDER BY expire_date DESC) AS rn
    FROM churn_events
    WHERE n_days = 30
      AND expire_date BETWEEN DATE '2017-02-01' AND DATE '2017-02-28'
)
SELECT t.is_churn,
       f.outcome AS my_outcome,
       COUNT(*)  AS cnt
FROM train_labels t
JOIN feb f USING (msno)
WHERE f.rn = 1 AND t.source = 'train'
GROUP BY ALL
ORDER BY ALL;
