-- 02_build_user_master.sql  (DuckDB)
-- 목적: 사용자 1행 = 분석 단위. 가입 정보 + 첫 결제 + 가입 초기 행동 + 이탈 여부를 한 테이블로 합침
-- 전제: 00, 01 실행 완료
-- 분석 대상: 결제 이력이 1건 이상 있는 회원 (구독 전환한 사용자)

CREATE OR REPLACE TABLE user_master AS
WITH first_tx AS (
    SELECT msno,
           MIN(transaction_date)                          AS first_tx_date,
           ARG_MIN(payment_plan_days, transaction_date)   AS first_plan_days,
           ARG_MIN(payment_method_id, transaction_date)   AS first_payment_method,
           ARG_MIN(is_auto_renew, transaction_date)       AS first_auto_renew
    FROM transactions_sample
    GROUP BY msno
),
log_range AS (
    SELECT MIN(log_date) AS log_start FROM user_logs_sample
),
-- 가입일 기준 초기 7일/30일 행동. 하루 총 청취시간은 이상치 방지를 위해 86,400초로 상한 처리
early AS (
    SELECT m.msno,
           COUNT(DISTINCT l.log_date) FILTER (
               WHERE l.log_date >= m.registration_date AND l.log_date < m.registration_date + 7
           ) AS active_days_7d,
           COUNT(DISTINCT l.log_date) FILTER (
               WHERE l.log_date >= m.registration_date AND l.log_date < m.registration_date + 30
           ) AS active_days_30d,
           SUM(LEAST(l.total_secs, 86400)) FILTER (
               WHERE l.log_date >= m.registration_date AND l.log_date < m.registration_date + 30
           ) AS listen_secs_30d,
           SUM(l.num_unq) FILTER (
               WHERE l.log_date >= m.registration_date AND l.log_date < m.registration_date + 30
           ) AS unique_songs_30d,
           -- 스킵 비율 = 25% 미만 재생 곡 / 전체 재생 곡
           SUM(l.num_25) FILTER (
               WHERE l.log_date >= m.registration_date AND l.log_date < m.registration_date + 30
           )::DOUBLE
           / NULLIF(SUM(l.num_25 + l.num_50 + l.num_75 + l.num_985 + l.num_100) FILTER (
               WHERE l.log_date >= m.registration_date AND l.log_date < m.registration_date + 30
           ), 0) AS skip_ratio_30d
    FROM members m
    JOIN user_logs_sample l USING (msno)
    GROUP BY m.msno
),
churn AS (
    SELECT msno,
           MAX(churned_final::INT) FILTER (WHERE n_days = 15) AS churned_15,
           MAX(churned_final::INT) FILTER (WHERE n_days = 30) AS churned_30,
           MAX(churned_final::INT) FILTER (WHERE n_days = 45) AS churned_45,
           MAX(ever_churned::INT)  FILTER (WHERE n_days = 30) AS ever_churned_30,
           MAX(n_returns)          FILTER (WHERE n_days = 30) AS n_returns_30,
           MAX(is_censored::INT)   FILTER (WHERE n_days = 30) AS is_censored_30,
           MIN(first_churn_expire_date) FILTER (WHERE n_days = 30) AS first_churn_date_30
    FROM user_churn
    GROUP BY msno
)
SELECT m.msno,
       m.registration_date,
       date_trunc('month', m.registration_date)::DATE AS cohort_month,
       m.city,
       CASE WHEN m.bd BETWEEN 10 AND 80 THEN m.bd END AS age,   -- 범위 밖 값은 결측 처리
       m.gender,
       m.registered_via,
       f.first_tx_date,
       f.first_plan_days,
       f.first_payment_method,
       f.first_auto_renew,
       e.active_days_7d,
       e.active_days_30d,
       e.listen_secs_30d,
       e.unique_songs_30d,
       e.skip_ratio_30d,
       -- 로그 수집 시작일 이후 가입자만 초기 행동 지표를 신뢰할 수 있음
       (m.registration_date >= r.log_start) AS has_early_window,
       c.churned_15, c.churned_30, c.churned_45,
       c.ever_churned_30, c.n_returns_30, c.is_censored_30, c.first_churn_date_30
FROM members m
JOIN first_tx f USING (msno)
LEFT JOIN early e USING (msno)
LEFT JOIN churn c USING (msno)
CROSS JOIN log_range r
WHERE m.msno IN (SELECT msno FROM sample_users);

-- 점검
SELECT COUNT(*)                                   AS users,
       COUNT(*) FILTER (WHERE has_early_window)   AS users_with_early_window,
       ROUND(AVG(churned_30), 4)                  AS churn_rate_30d_incl_censored_as_active
FROM user_master;
