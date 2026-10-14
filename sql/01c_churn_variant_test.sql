-- 01c_churn_variant_test.sql  (DuckDB)
-- 목적: 공식 is_churn 라벨이 "만료일 이후에 발생한 결제만 갱신으로 본다"는 가설을 검증
-- 전제: 01_churn_definition.sql, 01b_churn_label_diagnosis.sql 실행 완료 (label_check 테이블 필요)
--
-- 배경: 01b 결과에서 공식 이탈인데 내 정의가 갱신으로 본 사용자의 대부분은
--       만료일 이전에 다음 결제(조기 갱신, 장기 플랜 구매)가 있었음.
-- 비교하는 정의
--   mine : 내 정의 (조기 갱신도 갱신으로 인정, 취소 거래 제외)
--   v1   : 만료일 이후 30일 안에 결제(취소 제외)가 없으면 이탈
--   v2   : 만료일 이후 30일 안에 결제(취소 포함 전체)가 없으면 이탈
-- 주의: 이 결과는 어떤 정의가 공식 라벨과 더 비슷한지 보여 줄 뿐, 어느 쪽이 "옳다"는 뜻은 아님.

CREATE OR REPLACE TABLE label_variants AS
SELECT lc.msno,
       lc.is_churn,
       lc.expire_date,
       (lc.outcome IN ('churn', 'churn_then_return'))::INT AS mine,
       (NOT EXISTS (
            SELECT 1 FROM transactions_sample t
            WHERE t.msno = lc.msno
              AND t.is_cancel = 0
              AND t.transaction_date >= lc.expire_date
              AND t.transaction_date <= lc.expire_date + 30
       ))::INT AS v1,
       (NOT EXISTS (
            SELECT 1 FROM transactions_sample t
            WHERE t.msno = lc.msno
              AND t.transaction_date >= lc.expire_date
              AND t.transaction_date <= lc.expire_date + 30
       ))::INT AS v2
FROM label_check lc;

-- 1. 정의별 공식 라벨과의 일치도
--    caught: 공식 이탈자를 이탈로 잡은 수 / false_churn: 공식 갱신자를 이탈로 잘못 잡은 수
SELECT def,
       COUNT(*)                                        AS labeled_users,
       ROUND(AVG((flag = is_churn)::INT), 4)           AS agreement,
       COUNT(*) FILTER (WHERE is_churn = 1 AND flag = 1) AS caught,
       COUNT(*) FILTER (WHERE is_churn = 1)            AS official_churners,
       COUNT(*) FILTER (WHERE is_churn = 0 AND flag = 1) AS false_churn
FROM (
    SELECT 'mine' AS def, mine AS flag, is_churn FROM label_variants
    UNION ALL
    SELECT 'v1 (만료 후 결제만, 취소 제외)', v1, is_churn FROM label_variants
    UNION ALL
    SELECT 'v2 (만료 후 결제만, 취소 포함)', v2, is_churn FROM label_variants
)
GROUP BY def
ORDER BY def;

-- 2. 취소(is_cancel = 1) 거래 비율 비교: 불일치 사용자만 유독 높은지 확인
WITH cancel_flag AS (
    SELECT msno, MAX(is_cancel) AS has_cancel
    FROM transactions_sample
    WHERE transaction_date >= DATE '2017-01-15'
    GROUP BY msno
)
SELECT CASE WHEN lc.is_churn = 1 AND lc.outcome = 'renewed' THEN '3. 불일치 (공식 이탈 / 내 갱신)'
            WHEN lc.is_churn = 1                            THEN '2. 공식 이탈 / 내 이탈'
            ELSE '1. 공식 갱신' END                                AS grp,
       COUNT(*)                                                  AS users,
       ROUND(AVG(COALESCE(cf.has_cancel, 0)), 4)                 AS cancel_tx_share
FROM label_check lc
LEFT JOIN cancel_flag cf USING (msno)
GROUP BY ALL
ORDER BY ALL;
