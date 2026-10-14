-- 00_load_and_sample.sql  (DuckDB)
-- 목적: KKBox 원본 CSV 적재 -> 사용자 단위 샘플링 -> 분석용 테이블 생성
-- 실행(프로젝트 루트): duckdb data/kkbox.duckdb < sql/00_load_and_sample.sql
-- 주의: 파일명·컬럼명은 내려받은 파일 기준으로 확인하세요.

-- 0. 분석 파라미터
CREATE OR REPLACE TABLE params AS
SELECT DATE '2017-03-31' AS data_end,    -- 거래 데이터 마지막 반영일 (transactions_v2 기준)
       1                AS sample_pct;  -- 사용자 샘플링 비율(%)

-- 1. 회원 정보
CREATE OR REPLACE TABLE members AS
SELECT msno, city, bd, gender, registered_via,
       strptime(CAST(registration_init_time AS VARCHAR), '%Y%m%d')::DATE AS registration_date
FROM read_csv_auto('data/raw/members_v3.csv');

-- 2. 공식 이탈 라벨 (내가 정의한 이탈과 비교·검증용)
CREATE OR REPLACE TABLE train_labels AS
SELECT msno, is_churn, 'train'    AS source FROM read_csv_auto('data/raw/train.csv')
UNION ALL
SELECT msno, is_churn, 'train_v2' AS source FROM read_csv_auto('data/raw/train_v2.csv');

-- 3. 사용자 단위 샘플링 (hash 기반이라 실행할 때마다 같은 사용자가 뽑힘)
CREATE OR REPLACE TABLE sample_users AS
SELECT m.msno
FROM members m, params p
WHERE hash(m.msno) % 100 < p.sample_pct;

-- 4. 거래 내역 (두 파일 합치고 중복 제거)
CREATE OR REPLACE TABLE transactions_sample AS
SELECT DISTINCT
       msno, payment_method_id, payment_plan_days, plan_list_price,
       actual_amount_paid, is_auto_renew,
       strptime(CAST(transaction_date AS VARCHAR), '%Y%m%d')::DATE         AS transaction_date,
       strptime(CAST(membership_expire_date AS VARCHAR), '%Y%m%d')::DATE   AS membership_expire_date,
       is_cancel
FROM (
    SELECT * FROM read_csv_auto('data/raw/transactions.csv')
    UNION ALL
    SELECT * FROM read_csv_auto('data/raw/transactions_v2.csv')
) t
WHERE msno IN (SELECT msno FROM sample_users);

-- 5. 일별 청취 로그: 용량이 매우 커서 샘플 사용자만 뽑아 parquet로 저장 (1회만 실행)
COPY (
    SELECT l.msno,
           strptime(CAST(l.date AS VARCHAR), '%Y%m%d')::DATE AS log_date,
           l.num_25, l.num_50, l.num_75, l.num_985, l.num_100, l.num_unq, l.total_secs
    FROM read_csv_auto(['data/raw/user_logs.csv', 'data/raw/user_logs_v2.csv']) l
    WHERE l.msno IN (SELECT msno FROM sample_users)
) TO 'data/processed/user_logs_sample.parquet' (FORMAT PARQUET);

CREATE OR REPLACE TABLE user_logs_sample AS
SELECT * FROM read_parquet('data/processed/user_logs_sample.parquet');

-- 6. 적재 점검
SELECT 'members'              AS tbl, COUNT(*) AS n FROM members
UNION ALL SELECT 'sample_users',        COUNT(*) FROM sample_users
UNION ALL SELECT 'transactions_sample', COUNT(*) FROM transactions_sample
UNION ALL SELECT 'user_logs_sample',    COUNT(*) FROM user_logs_sample;
