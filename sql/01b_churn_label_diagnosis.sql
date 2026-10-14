-- 01b_churn_label_diagnosis.sql  (DuckDB)
-- 목적: 내 이탈 정의와 공식 is_churn 라벨이 어긋나는 이유를 데이터로 진단
-- 전제: 01_churn_definition.sql 실행 완료
-- 배경: 공식 라벨은 이탈(1)인데 내 정의는 갱신(renewed)으로 본 사용자가 있음.
--       원인 후보를 아래 쿼리로 하나씩 확인한다. (추측이 아니라 결과를 보고 판단)

-- 0. 비교용 테이블: 공식 라벨(train.csv) 사용자의 2017-02 만료 건 중 마지막 건
CREATE OR REPLACE TABLE label_check AS
WITH feb AS (
    SELECT msno, outcome, expire_date, next_tx_date,
           ROW_NUMBER() OVER (PARTITION BY msno ORDER BY expire_date DESC) AS rn
    FROM churn_events
    WHERE n_days = 30
      AND expire_date BETWEEN DATE '2017-02-01' AND DATE '2017-02-28'
)
SELECT t.msno, t.is_churn, f.outcome, f.expire_date, f.next_tx_date,
       date_diff('day', f.expire_date, f.next_tx_date) AS gap_days
FROM train_labels t
JOIN feb f USING (msno)
WHERE f.rn = 1 AND t.source = 'train';

-- 1. 일치도 요약 (caught = 공식 이탈자 중 내 정의도 이탈로 잡은 수)
SELECT COUNT(*)                                                                    AS labeled_users,
       ROUND(AVG(is_churn), 4)                                                     AS official_churn_rate,
       ROUND(AVG((outcome IN ('churn', 'churn_then_return'))::INT), 4)             AS my_churn_rate,
       ROUND(AVG(((outcome IN ('churn', 'churn_then_return'))::INT = is_churn)::INT), 4) AS agreement,
       COUNT(*) FILTER (WHERE is_churn = 1)                                        AS official_churners,
       COUNT(*) FILTER (WHERE is_churn = 1
                        AND outcome IN ('churn', 'churn_then_return'))             AS caught
FROM label_check;

-- 2. 불일치(공식 이탈 / 내 정의 갱신) 사용자는 다음 결제가 언제 있었는가
SELECT CASE WHEN gap_days < 0   THEN '1. 만료일 이전에 다음 결제'
            WHEN gap_days = 0   THEN '2. 만료 당일'
            WHEN gap_days <= 30 THEN '3. 만료 후 1~30일'
            ELSE '4. 기타' END AS gap_bucket,
       COUNT(*) AS users
FROM label_check
WHERE is_churn = 1 AND outcome = 'renewed'
GROUP BY ALL
ORDER BY ALL;

-- 3. 불일치 사용자 중 취소(is_cancel = 1) 거래가 있는 사용자 수
WITH mismatch AS (
    SELECT msno FROM label_check WHERE is_churn = 1 AND outcome = 'renewed'
)
SELECT COUNT(*)                                  AS mismatch_users,
       COUNT(*) FILTER (WHERE has_cancel = 1)    AS with_cancel_tx
FROM (
    SELECT m.msno, MAX(t.is_cancel) AS has_cancel
    FROM mismatch m
    JOIN transactions_sample t USING (msno)
    WHERE t.transaction_date >= DATE '2017-01-15'
    GROUP BY m.msno
);

-- 4. 불일치 사용자 5명의 거래 이력을 직접 확인 (눈으로 패턴 찾기)
SELECT t.msno, t.transaction_date, t.membership_expire_date,
       t.payment_plan_days, t.actual_amount_paid, t.is_auto_renew, t.is_cancel
FROM transactions_sample t
WHERE t.msno IN (SELECT msno FROM label_check
                 WHERE is_churn = 1 AND outcome = 'renewed'
                 ORDER BY msno LIMIT 5)
  AND t.transaction_date >= DATE '2016-12-01'
ORDER BY t.msno, t.transaction_date, t.membership_expire_date;
