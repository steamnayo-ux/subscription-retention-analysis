-- 03c_trial_check.sql  (DuckDB)
-- 목적: B 코호트에서 첫 결제가 7일 플랜인 사용자의 결제 금액 분포와 1차 갱신률 확인
--       (7일 플랜이 무료·저가 체험인지, 단기 유료 상품인지 구분)
-- 전제: 03_funnel.sql 실행 완료 (funnel_user)
-- 주의: 첫 거래가 같은 날 여러 건이면 ARG_MIN이 임의의 한 건을 고름 (건수가 적어 영향은 작을 것으로 가정)

WITH first_tx AS (
    SELECT msno,
           ARG_MIN(payment_plan_days, transaction_date)  AS plan_days,
           ARG_MIN(plan_list_price, transaction_date)    AS list_price,
           ARG_MIN(actual_amount_paid, transaction_date) AS paid_amt
    FROM transactions_sample
    WHERE is_cancel = 0
    GROUP BY msno
)
SELECT f.list_price,
       f.paid_amt,
       COUNT(*) FILTER (WHERE fu.r1_status IN ('renewed', 'churned'))  AS decided,
       COUNT(*) FILTER (WHERE fu.r1_status = 'renewed')                AS renewed,
       ROUND(100.0 * COUNT(*) FILTER (WHERE fu.r1_status = 'renewed')
             / NULLIF(COUNT(*) FILTER (WHERE fu.r1_status IN ('renewed', 'churned')), 0), 2) AS renew_pct
FROM funnel_user fu
JOIN first_tx f USING (msno)
WHERE fu.reg_in_window
  AND f.plan_days = 7
GROUP BY ALL
ORDER BY decided DESC
LIMIT 10;