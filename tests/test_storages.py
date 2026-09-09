#!/usr/bin/env python3
"""
Agora Storage User Connection & CRUD Test Suite (Python)
각 저장소(MS SQL, Elasticsearch, Redis Stack)의 .env 동적 설정을 기반으로
일반 사용자 계정 인증 및 CRUD/Search/Scope 제한 권한을 검증하는 Python 테스트 코드
"""

import os
import sys
import json
import base64
import urllib.request
import urllib.error
import subprocess
from pathlib import Path

# ANSI 색상 코드
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
RESET = "\033[0m"

ROOT_DIR = Path(__file__).resolve().parent.parent

def load_env_file(filepath: Path) -> dict:
    """간단한 .env 파서"""
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

# 설정 로드
mssql_env = load_env_file(ROOT_DIR / "mssql" / ".env")
es_env = load_env_file(ROOT_DIR / "elasticsearch" / ".env")
redis_env = load_env_file(ROOT_DIR / "redis" / ".env")

# MSSQL 설정
mssql_raw_host = mssql_env.get("MSSQL_EXTERNAL_IP", mssql_env.get("MSSQL_HOST", "127.0.0.1"))
MSSQL_HOST = "127.0.0.1" if mssql_raw_host == "0.0.0.0" else mssql_raw_host
MSSQL_PORT = mssql_env.get("MSSQL_EXTERNAL_PORT", mssql_env.get("MSSQL_PORT", "1433"))
MSSQL_DB = mssql_env.get("MSSQL_DB", "agora_db")
MSSQL_USER = mssql_env.get("MSSQL_USER", "agora_user")
MSSQL_PASS = mssql_env.get("MSSQL_PASSWORD", "AgoraUserSecret@Passw0rd!2026")
MSSQL_TABLE_USERS = mssql_env.get("MSSQL_TABLE_USERS", "users")
MSSQL_TABLE_REDIS_SERVER = mssql_env.get("MSSQL_TABLE_REDIS_SERVER", "redis_server")
MSSQL_TABLE_CANVAS_CACHE = mssql_env.get("MSSQL_TABLE_CANVAS_CACHE", "canvas_cache")

# Elasticsearch 설정
es_raw_ip = es_env.get("ES_EXTERNAL_IP", "127.0.0.1")
es_connect_ip = "127.0.0.1" if es_raw_ip == "0.0.0.0" else es_raw_ip
es_port = es_env.get("ES_EXTERNAL_PORT", es_env.get("ES_PORT", "9200"))
ES_HOST = f"http://{es_connect_ip}:{es_port}"
ES_INDEX = es_env.get("ES_INDEX", "canvas")
ES_USER = es_env.get("ES_USER_NAME", "agora_user")
ES_PASS = es_env.get("ES_USER_PASSWORD", "AgoraUserSecret@Passw0rd!2026")

# Redis 설정
redis_raw_host = redis_env.get("REDIS_EXTERNAL_IP", "127.0.0.1")
REDIS_HOST = "127.0.0.1" if redis_raw_host == "0.0.0.0" else redis_raw_host
REDIS_PORT = redis_env.get("REDIS_EXTERNAL_PORT", redis_env.get("REDIS_PORT", "6379"))
REDIS_USER = redis_env.get("REDIS_USER", "agora_user")
REDIS_PASS = redis_env.get("REDIS_USER_PASSWORD", "AgoraUserSecret@Passw0rd!2026")
REDIS_INDEX_NAME = redis_env.get("REDIS_INDEX_NAME", "idx:canvas")
REDIS_KEY_PREFIX = redis_env.get("REDIS_KEY_PREFIX", "canvas:")

results = []

def record_test(name: str, passed: bool, detail: str = ""):
    status = f"[{GREEN}PASS{RESET}]" if passed else f"[{RED}FAIL{RESET}]"
    print(f"  {status} {name}")
    if not passed and detail:
        print(f"         {RED}원인: {detail}{RESET}")
    results.append((name, passed))


# ==============================================================================
# 1. MS SQL 테스트
# ==============================================================================
def test_mssql():
    print(f"\n{YELLOW}[1/3] MS SQL Server CRUD 테스트 ({MSSQL_USER}@{MSSQL_HOST}:{MSSQL_PORT}/{MSSQL_DB}){RESET}")
    print(f"  - 검증 테이블: {MSSQL_TABLE_USERS}, {MSSQL_TABLE_REDIS_SERVER}, {MSSQL_TABLE_CANVAS_CACHE}")
    
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
        # (1-1) 인증 및 dbo 권한 검증
        auth_info = run_query("SELECT DB_NAME() + ':' + USER_NAME() + ':' + SUSER_SNAME();")
        is_dbo = f"{MSSQL_DB}:dbo:{MSSQL_USER}" in auth_info
        record_test(f"사용자 인증 및 DB 소유권 확인 ({MSSQL_USER} -> dbo)", is_dbo, auth_info)

        # (1-2) 환경변수 테이블 존재 여부 확인 (3개 테이블)
        tbl_cnt = run_query(f"SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME IN ('{MSSQL_TABLE_USERS}', '{MSSQL_TABLE_REDIS_SERVER}', '{MSSQL_TABLE_CANVAS_CACHE}');")
        record_test(f"환경변수 지정 테이블({MSSQL_TABLE_USERS}, {MSSQL_TABLE_REDIS_SERVER}, {MSSQL_TABLE_CANVAS_CACHE}) 생성 확인", tbl_cnt == "3", tbl_cnt)

        # (1-3) 회원 테이블(users) CRUD
        test_email = "test_py_user@agora.com"
        run_query(f"INSERT INTO [{MSSQL_TABLE_USERS}] (email, nickname, role, status) VALUES ('{test_email}', N'PyTester', 'ROLE_USER', 'ACTIVE');")
        u_ins = run_query(f"SELECT COUNT(*) FROM [{MSSQL_TABLE_USERS}] WHERE email = '{test_email}';")
        record_test(f"회원 테이블({MSSQL_TABLE_USERS}) 데이터 삽입 [Create] 성공", u_ins == "1", u_ins)

        u_read = run_query(f"SELECT status FROM [{MSSQL_TABLE_USERS}] WHERE email = '{test_email}';")
        record_test(f"회원 테이블({MSSQL_TABLE_USERS}) 데이터 조회 [Read] 성공 (status: ACTIVE)", u_read == "ACTIVE", u_read)

        run_query(f"UPDATE [{MSSQL_TABLE_USERS}] SET status = 'SUSPENDED' WHERE email = '{test_email}';")
        u_upd = run_query(f"SELECT status FROM [{MSSQL_TABLE_USERS}] WHERE email = '{test_email}';")
        record_test(f"회원 테이블({MSSQL_TABLE_USERS}) 데이터 수정 [Update] 성공 (ACTIVE -> SUSPENDED)", u_upd == "SUSPENDED", u_upd)

        run_query(f"DELETE FROM [{MSSQL_TABLE_USERS}] WHERE email = '{test_email}';")
        u_del = run_query(f"SELECT COUNT(*) FROM [{MSSQL_TABLE_USERS}] WHERE email = '{test_email}';")
        record_test(f"회원 테이블({MSSQL_TABLE_USERS}) 데이터 삭제 [Delete] 성공 (클린업 완료)", u_del == "0", u_del)

        # (1-4) 캐시 및 Redis 서버 테이블 CRUD
        test_cache_redis_ip = "127.0.0.99"
        test_cache_redis_port = "6399"
        run_query(f"INSERT INTO [{MSSQL_TABLE_REDIS_SERVER}] (redis_ip, redis_port) VALUES ('{test_cache_redis_ip}', '{test_cache_redis_port}');")
        run_query(f"INSERT INTO [{MSSQL_TABLE_CANVAS_CACHE}] (canvas_id, canvas_name, redis_ip, redis_port, is_cached) VALUES (8888, N'test-py-canvas', '{test_cache_redis_ip}', '{test_cache_redis_port}', 0);")
        ins_cnt = run_query(f"SELECT COUNT(*) FROM [{MSSQL_TABLE_CANVAS_CACHE}] WHERE canvas_id = 8888;")
        record_test(f"캐시 테이블({MSSQL_TABLE_REDIS_SERVER}, {MSSQL_TABLE_CANVAS_CACHE}) 데이터 삽입 [Create] 성공 (canvas_id: 8888)", ins_cnt == "1", ins_cnt)

        # (1-5) 데이터 조회 [Read]
        read_val = run_query(f"SELECT is_cached FROM [{MSSQL_TABLE_CANVAS_CACHE}] WHERE canvas_id = 8888;")
        record_test(f"캐시 테이블({MSSQL_TABLE_CANVAS_CACHE}) 데이터 조회 [Read] 성공 (is_cached: 0)", read_val == "0", read_val)

        # (1-6) 데이터 수정 [Update]
        run_query(f"UPDATE [{MSSQL_TABLE_CANVAS_CACHE}] SET is_cached = 1 WHERE canvas_id = 8888;")
        upd_val = run_query(f"SELECT is_cached FROM [{MSSQL_TABLE_CANVAS_CACHE}] WHERE canvas_id = 8888;")
        record_test(f"캐시 테이블({MSSQL_TABLE_CANVAS_CACHE}) 데이터 수정 [Update] 성공 (is_cached: 0 -> 1)", upd_val == "1", upd_val)

        # (1-7) 데이터 삭제 [Delete] (클린업)
        run_query(f"DELETE FROM [{MSSQL_TABLE_CANVAS_CACHE}] WHERE canvas_id = 8888;")
        run_query(f"DELETE FROM [{MSSQL_TABLE_REDIS_SERVER}] WHERE redis_ip = '{test_cache_redis_ip}' AND redis_port = '{test_cache_redis_port}';")
        del_cnt = run_query(f"SELECT COUNT(*) FROM [{MSSQL_TABLE_CANVAS_CACHE}] WHERE canvas_id = 8888;")
        record_test(f"캐시 테이블({MSSQL_TABLE_CANVAS_CACHE}, {MSSQL_TABLE_REDIS_SERVER}) 데이터 삭제 [Delete] 성공 (클린업 완료)", del_cnt == "0", del_cnt)
    except Exception as e:
        record_test("MS SQL 쿼리 실행 실패", False, str(e))


# ==============================================================================
# 2. Elasticsearch 테스트 (Python urllib 표준 라이브러리)
# ==============================================================================
def test_elasticsearch():
    print(f"\n{YELLOW}[2/3] Elasticsearch CRUD/Search 테스트 ({ES_USER}@{ES_HOST}, 인덱스: {ES_INDEX}){RESET}")
    
    auth_header = "Basic " + base64.b64encode(f"{ES_USER}:{ES_PASS}".encode()).decode()

    # (2-1) 사용자 인증 검증
    try:
        req = urllib.request.Request(f"{ES_HOST}/_security/_authenticate")
        req.add_header("Authorization", auth_header)
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
            is_auth = (data.get("username") == ES_USER)
            roles = data.get("roles", [])
            record_test(f"사용자 인증 성공 ({ES_USER}, roles: {roles})", is_auth)
    except Exception as e:
        record_test("사용자 인증 확인 실패", False, str(e))

    # (2-2) 인덱스 접근 확인
    try:
        req = urllib.request.Request(f"{ES_HOST}/{ES_INDEX}")
        req.add_header("Authorization", auth_header)
        with urllib.request.urlopen(req) as resp:
            record_test(f"인덱스({ES_INDEX}) 존재 및 접근 권한 확인", resp.status == 200)
    except Exception as e:
        record_test(f"인덱스({ES_INDEX}) 접근 확인 실패", False, str(e))

    doc_id = "test-py-doc"

    # (2-3) 도큐먼트 삽입 [Create]
    try:
        payload = json.dumps({"canvas-name": "Agora Test Canvas", "canvas-id": 7777, "admin": 100}).encode()
        req = urllib.request.Request(f"{ES_HOST}/{ES_INDEX}/_doc/{doc_id}?refresh=true", data=payload, method="PUT")
        req.add_header("Authorization", auth_header)
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
            res = data.get("result", "")
            record_test(f"인덱스({ES_INDEX}) 도큐먼트 삽입 [Create] 성공 (result: {res})", res in ("created", "updated"))
    except Exception as e:
        record_test(f"인덱스({ES_INDEX}) 도큐먼트 삽입 실패", False, str(e))

    # (2-4) 도큐먼트 단건 조회 [Read]
    try:
        req = urllib.request.Request(f"{ES_HOST}/{ES_INDEX}/_doc/{doc_id}")
        req.add_header("Authorization", auth_header)
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
            found = data.get("found", False)
            record_test(f"인덱스({ES_INDEX}) 도큐먼트 단건 조회 [Read] 성공", found)
    except Exception as e:
        record_test(f"인덱스({ES_INDEX}) 도큐먼트 단건 조회 실패", False, str(e))

    # (2-5) 검색 쿼리 (_search) [Search]
    try:
        query_payload = json.dumps({"query": {"match": {"canvas-name": "Agora"}}}).encode()
        req = urllib.request.Request(f"{ES_HOST}/{ES_INDEX}/_search", data=query_payload, method="POST")
        req.add_header("Authorization", auth_header)
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
            hits = data.get("hits", {}).get("total", {}).get("value", 0)
            record_test(f"인덱스({ES_INDEX}) match 검색 조회 [Search] (검색 결과 {hits}건)", hits >= 1)
    except Exception as e:
        record_test(f"인덱스({ES_INDEX}) match 검색 조회 실패", False, str(e))

    # (2-6) 도큐먼트 수정 [Update]
    try:
        update_payload = json.dumps({"doc": {"canvas-name": "Agora Test Canvas Updated"}}).encode()
        req = urllib.request.Request(f"{ES_HOST}/{ES_INDEX}/_update/{doc_id}", data=update_payload, method="POST")
        req.add_header("Authorization", auth_header)
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
            res = data.get("result", "")
            record_test(f"인덱스({ES_INDEX}) 도큐먼트 수정 [Update] 성공 (result: {res})", res == "updated")
    except Exception as e:
        record_test(f"인덱스({ES_INDEX}) 도큐먼트 수정 실패", False, str(e))

    # (2-7) 도큐먼트 삭제 [Delete]
    try:
        req = urllib.request.Request(f"{ES_HOST}/{ES_INDEX}/_doc/{doc_id}", method="DELETE")
        req.add_header("Authorization", auth_header)
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
            res = data.get("result", "")
            record_test(f"인덱스({ES_INDEX}) 도큐먼트 삭제 [Delete] 성공 (클린업 완료)", res == "deleted")
    except Exception as e:
        record_test(f"인덱스({ES_INDEX}) 도큐먼트 삭제 실패", False, str(e))


# ==============================================================================
# 3. Redis Stack 테스트
# ==============================================================================
def test_redis():
    print(f"\n{YELLOW}[3/3] Redis Stack CRUD/Search/Scope 테스트 ({REDIS_USER}@{REDIS_HOST}:{REDIS_PORT}){RESET}")
    print(f"  - 인덱스: {REDIS_INDEX_NAME}, 네임스페이스(Prefix): {REDIS_KEY_PREFIX}")

    def run_redis_cmd(*args) -> str:
        cmd = [
            "docker", "exec", "agora-redis-stack",
            "redis-cli",
            "--user", REDIS_USER,
            "-a", REDIS_PASS,
            "--no-auth-warning"
        ] + list(args)
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return res.stdout.strip()

    test_key = f"{REDIS_KEY_PREFIX}test-py"

    try:
        # (3-1) PING 인증 검증
        ping_res = run_redis_cmd("ping")
        record_test("사용자 ACL 인증 (PING -> PONG)", "PONG" in ping_res, ping_res)

        # (3-2) RediSearch 인덱스 정보 조회
        info_res = run_redis_cmd("FT.INFO", REDIS_INDEX_NAME)
        record_test(f"RediSearch 인덱스({REDIS_INDEX_NAME}) 정보 조회", REDIS_INDEX_NAME in info_res, info_res)

        # (3-3) RedisJSON 데이터 삽입 [Create]
        insert_res = run_redis_cmd("JSON.SET", test_key, "$", '{"canvas-name":"PyTest","canvas-id":555,"admin":1000}')
        record_test(f"RedisJSON 데이터 삽입 [Create] ({test_key})", "OK" in insert_res, insert_res)

        # (3-4) RedisJSON 데이터 조회 [Read]
        json_res = run_redis_cmd("JSON.GET", test_key)
        record_test(f"RedisJSON 데이터 조회 [Read] ({test_key})", "PyTest" in json_res, json_res)

        # (3-5) RediSearch 검색 쿼리 [Search]
        search_res = run_redis_cmd("FT.SEARCH", REDIS_INDEX_NAME, "@admin:[1000 1000]")
        record_test(f"RediSearch 검색 쿼리 [Search] (FT.SEARCH {REDIS_INDEX_NAME})", test_key in search_res, search_res)

        # (3-6) RedisJSON 데이터 수정 [Update]
        update_res = run_redis_cmd("JSON.SET", test_key, "$.admin", "2000")
        record_test(f"RedisJSON 데이터 수정 [Update] ({test_key} $.admin 2000)", "OK" in update_res, update_res)

        # (3-7) RedisJSON 데이터 삭제 [Delete]
        del_res = run_redis_cmd("DEL", test_key)
        record_test(f"RedisJSON 데이터 삭제 [Delete] ({test_key})", "1" in del_res, del_res)

        # (3-8) 타 키 접근 차단 검증 [Scope Restriction]
        try:
            forbid_res = run_redis_cmd("SET", "other:forbidden", "val")
            record_test("타 네임스페이스 키 접근 차단 [Scope Restriction]", "NOPERM" in forbid_res, forbid_res)
        except subprocess.CalledProcessError as err:
            err_output = err.stderr or err.stdout
            record_test("타 네임스페이스 키 접근 차단 [Scope Restriction] (NOPERM 거절 확인)", "NOPERM" in err_output, err_output)
    except Exception as e:
        record_test("Redis 명령어 실행 실패", False, str(e))


def main():
    print(f"{CYAN}================================================================{RESET}")
    print(f"{CYAN}      Agora Storage User Connection & CRUD Test (Python)        {RESET}")
    print(f"{CYAN}================================================================{RESET}")

    test_mssql()
    test_elasticsearch()
    test_redis()

    passed = sum(1 for _, ok in results if ok)
    total = len(results)
    failed = total - passed

    print(f"\n{CYAN}================================================================{RESET}")
    print(f"{CYAN}                        테스트 결과 요약                        {RESET}")
    print(f"{CYAN}================================================================{RESET}")
    print(f"  전체 테스트 수: {total}")
    print(f"  성공(PASSED):   {GREEN}{passed}{RESET}")
    print(f"  실패(FAILED):   {RED}{failed}{RESET}")
    print(f"{CYAN}================================================================{RESET}")

    if failed == 0:
        print(f"\n{GREEN}[SUCCESS] 모든 저장소의 Python CRUD 테스트를 성공적으로 통과했습니다! (저장소 데이터 무결성 유지){RESET}\n")
        sys.exit(0)
    else:
        print(f"\n{RED}[FAILURE] 일부 테스트 항목이 실패했습니다.{RESET}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
