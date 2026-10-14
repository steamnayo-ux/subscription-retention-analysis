"""SQL 파일을 DuckDB에서 순서대로 실행하는 간단한 러너.

duckdb 명령줄 프로그램 없이 `pip install duckdb`만으로 SQL 파일을 실행하기 위한 스크립트입니다.
SELECT 결과는 터미널에 출력하고, 오류가 나면 어떤 SQL 문에서 났는지 보여 줍니다.

사용법 (프로젝트 루트에서 실행):
    python python/run_sql.py sql/00_load_and_sample.sql
    python python/run_sql.py sql/01_churn_definition.sql sql/02_build_user_master.sql
    python python/run_sql.py --db data/kkbox.duckdb sql/01_churn_definition.sql
"""
import argparse
import sys
import time
from pathlib import Path

import duckdb

MAX_ROWS = 30


def first_keyword(query: str) -> str:
    """주석을 건너뛰고 SQL 문의 첫 단어를 대문자로 반환."""
    for line in query.splitlines():
        line = line.strip()
        if line and not line.startswith("--"):
            return line.split()[0].upper()
    return ""


def print_result(cur) -> None:
    rows = cur.fetchall()
    if not rows:
        return
    headers = [d[0] for d in cur.description]
    print(" | ".join(headers))
    for row in rows[:MAX_ROWS]:
        print(" | ".join("" if v is None else str(v) for v in row))
    if len(rows) > MAX_ROWS:
        print(f"... ({len(rows)}행 중 {MAX_ROWS}행만 표시)")
    print()


def split_statements(con, sql: str) -> list[str]:
    try:
        return [s.query for s in con.extract_statements(sql)]
    except AttributeError:  # 오래된 duckdb 버전
        return [s for s in sql.split(";") if s.strip()]


def run_file(con, path: str) -> None:
    sql = Path(path).read_text(encoding="utf-8")
    statements = split_statements(con, sql)
    start = time.time()
    print(f"\n=== {path} ({len(statements)}개 SQL 문) ===")
    for i, query in enumerate(statements, 1):
        if not first_keyword(query):
            continue
        try:
            cur = con.execute(query)
        except Exception as e:
            preview = " ".join(query.split())[:200]
            print(f"\n[오류] {path}, {i}번째 SQL 문\n{preview}\n\n{e}")
            sys.exit(1)
        if first_keyword(query) in ("SELECT", "WITH"):
            print_result(cur)
    print(f"완료 ({time.time() - start:.1f}초)")


def main() -> None:
    parser = argparse.ArgumentParser(description="DuckDB로 SQL 파일 실행")
    parser.add_argument("sql_files", nargs="+", help="실행할 SQL 파일 (순서대로)")
    parser.add_argument("--db", default="data/kkbox.duckdb", help="DuckDB 파일 경로")
    args = parser.parse_args()

    if not Path("data/raw").exists():
        sys.exit("프로젝트 루트(data/raw 폴더가 있는 위치)에서 실행하세요.")

    Path(args.db).parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(args.db)
    for f in args.sql_files:
        run_file(con, f)
    con.close()


if __name__ == "__main__":
    main()
