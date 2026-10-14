-- 03b_funnel_by_plan.sql  (DuckDB)
-- 목적: B 코호트(관측 기간 내 가입)의 1차 갱신률을 첫 결제 플랜 길이·자동 갱신 여부별로 비교
-- 전제: 03_funnel.sql 실행 완료 (funnel_user), 02 실행 완료 (user_master)
-- 주의: user_master의 first_* 컬럼은 취소 거래도 포함해 첫 거래를 잡음 (99명 차이와 같은 이유)

SELECT um.first_plan_days,
       um.first_auto_renew,
       COUNT(*) FILTER (WHERE fu.r1_status IN ('renewed', 'churned'))  AS decided,
       COUNT(*) FILTER (WHERE fu.r1_status = 'renewed')                AS renewed,
       ROUND(100.0 * COUNT(*) FILTER (WHERE fu.r1_status = 'renewed')
             / NULLIF(COUNT(*) FILTER (WHERE fu.r1_status IN ('renewed', 'churned')), 0), 2) AS renew_pct
FROM funnel_user fu
JOIN user_master um USING (msno)
WHERE fu.reg_in_window
GROUP BY ALL
HAVING COUNT(*) FILTER (WHERE fu.r1_status IN ('renewed', 'churned')) >= 100   -- 표본이 너무 작은 조합은 제외
ORDER BY decided DESC;