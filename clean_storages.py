#!/usr/bin/env python3
"""
Agora Storage Batch Data Cleanup Script (Python)
현재 실행 중인 모든 저장소(MS SQL, Elasticsearch, Redis Stack)의 데이터를
스키마 및 인덱스 구조 손상 없이 일괄적으로 안전하게 초기화(삭제)합니다.
"""

import sys
import argparse
import base64
import json
import urllib.request
import urllib.error
import subprocess
from pathlib import Path

try:
    import redis as redis_lib
except ImportError:
    redis_lib = None

# ANSI 색상 코드
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"

ROOT_DIR = Path(__file__).resolve().parent


def load_env_file(filepath: Path) -> dict:
    """간단한 .env 파일 파서"""
    config = {}
    if filepath.exists():
        with open(filepath, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                config[k.strip()] = v.strip().split("#")[0].strip()
    return config


# 설정 파일 로드
mssql_env = load_env_file(ROOT_DIR / "mssql" / ".env")
es_env = load_env_file(ROOT_DIR / "elasticsearch" / ".env")
redis_env = load_env_file(ROOT_DIR / "redis" / ".env")

# MSSQL 설정
mssql_raw_host = mssql_env.get("MSSQL_EXTERNAL_IP", mssql_env.get("MSSQL_HOST", "127.0.0.1"))
MSSQL_HOST = "127.0.0.1" if mssql_raw_host in ("0.0.0.0", "") else mssql_raw_host
MSSQL_PORT = mssql_env.get("MSSQL_EXTERNAL_PORT", mssql_env.get("MSSQL_PORT", "1433"))
MSSQL_DB = mssql_env.get("MSSQL_DB", "agora_db")
MSSQL_USER = mssql_env.get("MSSQL_USER", "agora_user")
MSSQL_PASS = mssql_env.get("MSSQL_PASSWORD", "")
MSSQL_TABLE_USERS = mssql_env.get("MSSQL_TABLE_USERS", "users")
MSSQL_TABLE_REDIS_SERVER = mssql_env.get("MSSQL_TABLE_REDIS_SERVER", "redis_server")
MSSQL_TABLE_CANVAS_INFO = mssql_env.get("MSSQL_TABLE_CANVAS_INFO", "canvas_info")
MSSQL_TABLE_CPP_SERVER = mssql_env.get("MSSQL_TABLE_CPP_SERVER", "cpp_server")

# Elasticsearch 설정
es_raw_ip = es_env.get("ES_EXTERNAL_IP", "127.0.0.1")
es_connect_ip = "127.0.0.1" if es_raw_ip in ("0.0.0.0", "") else es_raw_ip
es_port = es_env.get("ES_EXTERNAL_PORT", es_env.get("ES_PORT", "9200"))
ES_HOST = f"http://{es_connect_ip}:{es_port}"
ES_INDEX = es_env.get("ES_INDEX", "canvas")
ES_USER = es_env.get("ES_USER_NAME", "agora_user")
ES_PASS = es_env.get("ES_USER_PASSWORD", "")

# Redis 설정
redis_raw_host = redis_env.get("REDIS_BIND_IP", redis_env.get("REDIS_EXTERNAL_IP", "127.0.0.1"))
REDIS_HOST = "127.0.0.1" if redis_raw_host in ("0.0.0.0", "") else redis_raw_host
REDIS_PORT = redis_env.get("REDIS_EXTERNAL_PORT", redis_env.get("REDIS_PORT", "6379"))
REDIS_ADMIN_PASS = redis_env.get("REDIS_PASSWORD", "")
REDIS_USER = redis_env.get("REDIS_USER", "agora_user")
REDIS_PASS = redis_env.get("REDIS_USER_PASSWORD", "")
REDIS_INDEX_NAME = redis_env.get("REDIS_INDEX_NAME", "idx:canvas")
REDIS_KEY_PREFIX = redis_env.get("REDIS_KEY_PREFIX", "canvas:")


def clean_mssql(re_register_redis: bool = True) -> bool:
    print(f"\n{YELLOW}[1/3] MS SQL Server 데이터 삭제 중... ({MSSQL_USER}@{MSSQL_HOST}:{MSSQL_PORT}/{MSSQL_DB}){RESET}")

    def run_query(sql: str) -> str:
        cmd = [
            "docker", "exec", "agora-mssql",
            "/opt/mssql-tools18/bin/sqlcmd",
            "-S", "localhost",
            "-U", MSSQL_USER,
            "-P", MSSQL_PASS,
            "-C", "-I", "-d", MSSQL_DB,
            "-W", "-h", "-1",
            "-Q", f"SET NOCOUNT ON; {sql}"
        ]
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return res.stdout.strip()

    try:
        count_sql = f"""
        SELECT
          (SELECT COUNT(*) FROM [{MSSQL_TABLE_USERS}]) AS u,
          (SELECT COUNT(*) FROM [user_sessions]) AS s,
          (SELECT COUNT(*) FROM [{MSSQL_TABLE_CANVAS_INFO}]) AS c,
          (SELECT COUNT(*) FROM [{MSSQL_TABLE_REDIS_SERVER}]) AS r,
          (SELECT COUNT(*) FROM [{MSSQL_TABLE_CPP_SERVER}]) AS p;
        """
        before = run_query(count_sql)
        print(f"  - 삭제 전 레코드 수: {before} (users, user_sessions, canvas_info, redis_server, cpp_server)")

        del_sql = f"""
        BEGIN TRANSACTION;
          DELETE FROM [user_sessions];
          DELETE FROM [{MSSQL_TABLE_CANVAS_INFO}];
          DELETE FROM [{MSSQL_TABLE_USERS}];
          DELETE FROM [{MSSQL_TABLE_CPP_SERVER}];
          DELETE FROM [{MSSQL_TABLE_REDIS_SERVER}];

          IF OBJECT_ID('{MSSQL_TABLE_USERS}', 'U') IS NOT NULL DBCC CHECKIDENT ('[{MSSQL_TABLE_USERS}]', RESEED, 0);
          IF OBJECT_ID('{MSSQL_TABLE_CANVAS_INFO}', 'U') IS NOT NULL DBCC CHECKIDENT ('[{MSSQL_TABLE_CANVAS_INFO}]', RESEED, 0);
          IF OBJECT_ID('{MSSQL_TABLE_CPP_SERVER}', 'U') IS NOT NULL DBCC CHECKIDENT ('[{MSSQL_TABLE_CPP_SERVER}]', RESEED, 0);
          IF OBJECT_ID('{MSSQL_TABLE_REDIS_SERVER}', 'U') IS NOT NULL DBCC CHECKIDENT ('[{MSSQL_TABLE_REDIS_SERVER}]', RESEED, 0);
        COMMIT TRANSACTION;
        """
        run_query(del_sql)

        if re_register_redis:
            reg_script = ROOT_DIR / "redis" / "register-to-mssql.sh"
            if reg_script.exists():
                print("  - 현재 실행 중인 Redis 인스턴스 정보 재등록 중...")
                subprocess.run(["bash", str(reg_script)], capture_output=True, text=True, check=True)
                print("  - [OK] Redis 서버 인스턴스 자동 재등록 완료")

        after = run_query(count_sql)
        print(f"  [{GREEN}OK{RESET}] MS SQL 테이블 데이터 삭제 완료 (삭제 후 상태: {after})")
        return True
    except Exception as e:
        print(f"  [{RED}FAIL{RESET}] MS SQL 데이터 삭제 중 오류 발생: {e}")
        return False


def clean_elasticsearch() -> bool:
    print(f"\n{YELLOW}[2/3] Elasticsearch 데이터 삭제 중... ({ES_USER}@{ES_HOST}, 인덱스: {ES_INDEX}){RESET}")
    auth_header = "Basic " + base64.b64encode(f"{ES_USER}:{ES_PASS}".encode()).decode()

    try:
        # 삭제 전 도큐먼트 수 확인
        count_req = urllib.request.Request(f"{ES_HOST}/{ES_INDEX}/_count")
        count_req.add_header("Authorization", auth_header)
        with urllib.request.urlopen(count_req, timeout=5) as resp:
            data = json.loads(resp.read().decode())
            before_cnt = data.get("count", 0)
            print(f"  - 삭제 전 도큐먼트 수: {before_cnt} 건")

        # _delete_by_query 실행
        del_payload = json.dumps({"query": {"match_all": {}}}).encode()
        del_req = urllib.request.Request(
            f"{ES_HOST}/{ES_INDEX}/_delete_by_query?conflicts=proceed&refresh=true",
            data=del_payload,
            method="POST"
        )
        del_req.add_header("Authorization", auth_header)
        del_req.add_header("Content-Type", "application/json")

        with urllib.request.urlopen(del_req, timeout=10) as resp:
            del_data = json.loads(resp.read().decode())
            deleted_cnt = del_data.get("deleted", 0)

        # 삭제 후 확인
        with urllib.request.urlopen(count_req, timeout=5) as resp:
            after_data = json.loads(resp.read().decode())
            after_cnt = after_data.get("count", 0)

        print(f"  [{GREEN}OK{RESET}] Elasticsearch 인덱스({ES_INDEX}) 도큐먼트 {deleted_cnt}건 삭제 완료 (현재 도큐먼트: {after_cnt} 건)")
        return True
    except Exception as e:
        print(f"  [{RED}FAIL{RESET}] Elasticsearch 데이터 삭제 중 오류 발생: {e}")
        return False


def clean_redis() -> bool:
    print(f"\n{YELLOW}[3/3] Redis Stack 데이터 삭제 중... ({REDIS_USER}@{REDIS_HOST}:{REDIS_PORT}){RESET}")
    print(f"  - 네임스페이스(Prefix): {REDIS_KEY_PREFIX}*, 인덱스: {REDIS_INDEX_NAME}")

    def run_cli_cmd(*args) -> str:
        cmd = [
            "docker", "exec",
            "-e", f"REDISCLI_AUTH={REDIS_ADMIN_PASS}",
            "agora-redis-stack",
            "redis-cli"
        ] + list(args)
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return res.stdout.strip()

    try:
        if redis_lib is not None:
            r = redis_lib.Redis(
                host=REDIS_HOST,
                port=int(REDIS_PORT),
                password=REDIS_ADMIN_PASS,
                decode_responses=True
            )
            total_before = r.dbsize()
            print(f"  - 삭제 전 전체 키 수: {total_before} 건")

            # canvas:* 패턴 키 검색 및 삭제
            keys = r.keys(f"{REDIS_KEY_PREFIX}*")
            deleted_cnt = 0
            if keys:
                deleted_cnt = r.delete(*keys)

            # RediSearch 인덱스 존재 확인
            try:
                r.execute_command("FT.INFO", REDIS_INDEX_NAME)
            except Exception:
                # 인덱스 재생성
                run_cli_cmd(
                    "FT.CREATE", REDIS_INDEX_NAME, "ON", "JSON", "PREFIX", "1", REDIS_KEY_PREFIX, "SCHEMA",
                    '$["canvas-name"]', "AS", "canvas_name", "TEXT", "SORTABLE",
                    '$["canvas-id"]', "AS", "canvas_id", "NUMERIC", "SORTABLE",
                    '$["admin-user-id"]', "AS", "admin_user_id", "NUMERIC",
                    '$.description', "AS", "description", "TEXT",
                    '$["canvas-password-hash"]', "AS", "canvas_password_hash", "TAG",
                    '$.people[*]', "AS", "people", "NUMERIC",
                    '$["init-group"]', "AS", "init_group", "TAG"
                )
                print(f"  - [OK] RediSearch 인덱스({REDIS_INDEX_NAME}) 스키마 복구 완료")

            total_after = r.dbsize()
            print(f"  [{GREEN}OK{RESET}] Redis 키 {deleted_cnt}건 삭제 완료 (현재 남은 전체 키: {total_after}건)")
        else:
            total_before = run_cli_cmd("DBSIZE")
            print(f"  - 삭제 전 전체 키 수: {total_before} 건")

            del_lua = "local keys = redis.call('keys', ARGV[1]); if #keys > 0 then return redis.call('del', unpack(keys)) else return 0 end"
            deleted_cnt = run_cli_cmd("EVAL", del_lua, "0", f"{REDIS_KEY_PREFIX}*")

            ft_list = run_cli_cmd("FT._LIST")
            if REDIS_INDEX_NAME not in ft_list:
                run_cli_cmd(
                    "FT.CREATE", REDIS_INDEX_NAME, "ON", "JSON", "PREFIX", "1", REDIS_KEY_PREFIX, "SCHEMA",
                    '$["canvas-name"]', "AS", "canvas_name", "TEXT", "SORTABLE",
                    '$["canvas-id"]', "AS", "canvas_id", "NUMERIC", "SORTABLE",
                    '$["admin-user-id"]', "AS", "admin_user_id", "NUMERIC",
                    '$.description', "AS", "description", "TEXT",
                    '$["canvas-password-hash"]', "AS", "canvas_password_hash", "TAG",
                    '$.people[*]', "AS", "people", "NUMERIC",
                    '$["init-group"]', "AS", "init_group", "TAG"
                )
                print(f"  - [OK] RediSearch 인덱스({REDIS_INDEX_NAME}) 스키마 복구 완료")

            total_after = run_cli_cmd("DBSIZE")
            print(f"  [{GREEN}OK{RESET}] Redis 키 {deleted_cnt}건 삭제 완료 (현재 남은 전체 키: {total_after}건)")

        return True
    except Exception as e:
        print(f"  [{RED}FAIL{RESET}] Redis 데이터 삭제 중 오류 발생: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(description="Agora Storage Batch Data Cleanup Script")
    parser.add_argument("-y", "--yes", "--force", dest="force", action="store_true", help="확인 프롬프트를 건너뛰고 즉시 삭제를 진행합니다")
    parser.add_argument("--no-re-register", dest="no_re_register", action="store_true", help="Redis 서버(redis_server) 자동 재등록을 건너뜁니다")
    args = parser.parse_args()

    print(f"{CYAN}================================================================{RESET}")
    print(f"{CYAN}        Agora Storage Batch Data Cleanup (데이터 일괄 삭제)     {RESET}")
    print(f"{CYAN}================================================================{RESET}")
    print("대상 저장소:")
    print("  1. MS SQL Server (회원, 세션, 캔버스 메타데이터, 서버 등록 테이블)")
    print("  2. Elasticsearch (캔버스 문서 및 인덱스 내 데이터)")
    print("  3. Redis Stack   (RedisJSON 캔버스 캐시 및 RediSearch 데이터)")
    print(f"{CYAN}================================================================{RESET}\n")

    if not args.force:
        print(f"{YELLOW}⚠️  [경고] 모든 저장소의 레코드 및 문서가 완전히 삭제됩니다.{RESET}")
        print("   (테이블 스키마, 제약조건, RediSearch/ES 매핑 구조는 보존됩니다)")
        ans = input("정말로 일괄 삭제를 진행하시겠습니까? [y/N]: ").strip().lower()
        if ans not in ("y", "yes"):
            print(f"\n{YELLOW}[INFO] 사용자에 의해 데이터 삭제 작업이 취소되었습니다.{RESET}\n")
            sys.exit(0)

    ok_mssql = clean_mssql(re_register_redis=not args.no_re_register)
    ok_es = clean_elasticsearch()
    ok_redis = clean_redis()

    print(f"\n{CYAN}================================================================{RESET}")
    print(f"{CYAN}              저장소 데이터 일괄 삭제 작업 완료                 {RESET}")
    print(f"{CYAN}================================================================{RESET}")
    print(f"  - MS SQL Server : {'성공' if ok_mssql else '실패'}")
    print(f"  - Elasticsearch : {'성공' if ok_es else '실패'}")
    print(f"  - Redis Stack   : {'성공' if ok_redis else '실패'}")
    print(f"{CYAN}================================================================{RESET}")

    if ok_mssql and ok_es and ok_redis:
        print(f"\n{GREEN}[SUCCESS] 모든 저장소가 깨끗한 초기 상태로 초기화되었습니다!{RESET}\n")
        sys.exit(0)
    else:
        print(f"\n{RED}[FAILURE] 일부 저장소 초기화 중 오류가 발생했습니다.{RESET}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
