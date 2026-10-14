# 구독 서비스 고객 이탈·리텐션 분석 (KKBox)

> 🚧 **작업 중입니다.** 아래 "진행 현황"에서 완료된 항목만 결과로 인정해 주세요.

음악 스트리밍 구독 서비스 KKBox의 가입·결제·청취 로그로 **가입 후 고객이 언제, 어떤 특징을 가지고 이탈하는지** 분석하고, 리텐션 개선을 위한 CRM 액션과 A/B 테스트 설계안을 제안하는 포트폴리오입니다.

## 분석 질문

1. 가입한 고객은 첫 결제와 갱신 단계에서 어디서 가장 많이 빠져나가는가? (구독 전환·갱신 퍼널)
2. 가입 후 이탈하는 고객은 어떤 특징을 가지는가?
3. 가입월 코호트별 월별 재방문(유지)율은 어떻게 다른가?
4. 고객 세그먼트별 행동과 유지율, LTV(근사치)는 어떻게 다른가?

### 초기 가설 (분석 후 수정 예정)

- H1. 가입 후 초기 30일 활동이 적은 사용자일수록 이탈 확률이 높다.
- H2. 자동 갱신을 켠 사용자는 이탈률이 낮다.
- H3. 결제수단과 플랜 기간에 따라 유지율이 다르다.

## 진행 현황

- [x] 저장소 생성, 폴더 구조
- [x] SQL 초안 (적재·샘플링, 이탈 정의, 사용자 마스터)
- [ ] 실제 데이터 적재와 데이터 점검 (EDA)
- [ ] 이탈 정의 확정과 민감도 분석
- [ ] 구독 전환·갱신 퍼널
- [ ] 코호트 유지율
- [ ] 이탈 고객 특징 (통계 검정, 회귀, 생존곡선)
- [ ] 세그먼트별 행동 차이, LTV
- [ ] A/B 테스트 설계안
- [ ] Excel 요약, 대시보드
- [ ] 핵심 결과와 한계 정리

## 데이터

- 출처: [WSDM - KKBox's Churn Prediction Challenge (Kaggle)](https://www.kaggle.com/c/kkbox-churn-prediction-challenge/data)
- 사용 파일: `members_v3`, `transactions`, `transactions_v2`, `user_logs`, `user_logs_v2`, `train`, `train_v2`
- 원본 데이터는 저장소에 포함하지 않습니다. 사용 조건은 Kaggle 대회 페이지에서 확인하세요.
- 데이터 용량이 커서 **사용자 단위 샘플링**(기본 10%)한 데이터로 분석합니다.

## 분석 기준

> 작성 예정: 이탈 정의(만료 후 N일), 민감도(N=15/30/45), 샘플링 방식, 제외한 데이터, 공식 `is_churn` 라벨과의 비교 결과

## 핵심 결과

> 분석 완료 후 작성

## 제안

> 분석 완료 후 작성 (세그먼트별 CRM 액션, A/B 테스트 설계안). 실제 효과는 실험으로 검증이 필요합니다.

## AI 활용과 검증

> 작성 예정: AI를 활용한 부분과, 결과를 직접 검증한 방법

## 한계

> 작성 예정: 데이터 시점, 관측되지 않은 요인, 관찰 데이터로서의 해석 한계

## 폴더 구조

```
subscription-retention-analysis/
├─ data/
│  ├─ raw/            # 원본 (저장소에 포함하지 않음)
│  └─ processed/      # 집계 결과 CSV 등
├─ sql/               # 00 적재·샘플링 → 01 이탈 정의 → 02 사용자 마스터 → ...
├─ notebooks/         # EDA, 통계 분석, 시각화
├─ python/            # 재사용 함수
├─ excel/             # 요약 리포트
├─ images/            # 분석 결과 이미지
└─ requirements.txt
```

## 실행 방법

1. Kaggle에서 위 데이터를 내려받아 `data/raw/`에 넣습니다.
2. 패키지를 설치합니다.

   ```
   pip install -r requirements.txt
   ```

3. 프로젝트 루트에서 SQL을 순서대로 실행합니다. (DuckDB, `data/kkbox.duckdb`에 결과 저장)

   ```
   python python/run_sql.py sql/00_load_and_sample.sql
   python python/run_sql.py sql/01_churn_definition.sql
   python python/run_sql.py sql/02_build_user_master.sql
   ```

   `00`은 대용량 로그를 읽어 시간이 오래 걸리므로 처음에는 `sample_pct`를 1로 낮춰 시험하세요.

## 기술 스택

- **SQL (DuckDB)**: 적재, 이탈 정의, 퍼널·코호트 집계 (CTE, 윈도우 함수)
- **Python**: pandas, scipy, statsmodels, lifelines, matplotlib, seaborn
- **Excel**: 요약 리포트
- **Git / GitHub**: 버전 관리
