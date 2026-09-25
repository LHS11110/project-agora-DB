#!/usr/bin/env python3
"""
Agora Unified Storage Search & Inspection Script (Python)
모든 저장소(MS SQL, Elasticsearch, Redis Stack)의 현재 적재 데이터를 일괄 조회/검색합니다.
"""

import sys
import argparse
import base64
import json
import urllib.request
import urllib.error
import subprocess
from pathlib import Path

# 색상 정의
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"

ROOT_DIR = Path(__file__).resolve().parent


def load_env_file(filepath: Path) -> dict:
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

# MSSQL
mssql_raw_host = mssql_env.get("MSSQL_EXTERNAL_IP", mssql_env.get("MSSQL_HOST", "127.0.0.1"))
MSSQL_HOST = "127.0.0.1" if mssql_raw_host in ("0.0.0.0", "") else mssql_raw_host
MSSQL_PORT = mssql_env.get("MSSQL_EXTERNAL_PORT", mssql_env.get("MSSQL_PORT", "1433"))
MSSQL_DB = mssql_env.get("MSSQL_DB", "agora_db")
MSSQL_USER = mssql_env.get("MSSQL_USER", "agora_user")
MSSQL_PASS = mssql_env.get("MSSQL_PASSWORD", "")
MSSQL_TABLES = [
    mssql_env.get("MSSQL_TABLE_USERS", "users"),
    "user_sessions",
    mssql_env.get("MSSQL_TABLE_CANVAS_INFO", "canvas_info"),
    mssql_env.get("MSSQL_TABLE_REDIS_SERVER", "redis_server"),
    mssql_env.get("MSSQL_TABLE_CPP_SERVER", "cpp_server")
]

# Elasticsearch
es_raw_ip = es_env.get("ES_EXTERNAL_IP", "127.0.0.1")
es_connect_ip = "127.0.0.1" if es_raw_ip in ("0.0.0.0", "") else es_raw_ip
es_port = es_env.get("ES_EXTERNAL_PORT", es_env.get("ES_PORT", "9200"))
ES_HOST = f"http://{es_connect_ip}:{es_port}"
ES_INDEX = es_env.get("ES_INDEX", "canvas")
ES_USER = es_env.get("ES_USER_NAME", "agora_user")
ES_PASS = es_env.get("ES_USER_PASSWORD", "")

# Redis
redis_raw_host = redis_env.get("REDIS_BIND_IP", redis_env.get("REDIS_EXTERNAL_IP", "127.0.0.1"))
REDIS_HOST = "127.0.0.1" if redis_raw_host in ("0.0.0.0", "") else redis_raw_host
REDIS_PORT = redis_env.get("REDIS_EXTERNAL_PORT", redis_env.get("REDIS_PORT", "6379"))
REDIS_ADMIN_PASS = redis_env.get("REDIS_PASSWORD", "")
REDIS_USER = redis_env.get("REDIS_USER", "agora_user")
REDIS_INDEX_NAME = redis_env.get("REDIS_INDEX_NAME", "idx:canvas")
REDIS_KEY_PREFIX = redis_env.get("REDIS_KEY_PREFIX", "canvas:")


def search_mssql(query_keyword: str = ""):
    print(f"\n{CYAN}[1/3] MS SQL Server 데이터 조회 ({MSSQL_USER}@{MSSQL_HOST}:{MSSQL_PORT}/{MSSQL_DB}){RESET}")

    def run_query(sql: str) -> str:
        cmd = [
            "docker", "exec", "agora-mssql",
            "/opt/mssql-tools18/bin/sqlcmd",
            "-S", "localhost",
            "-U", MSSQL_USER,
            "-P", MSSQL_PASS,
            "-C", "-I", "-d", MSSQL_DB,
            "-W",
            "-Q", f"SET NOCOUNT ON; {sql}"
        ]
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return res.stdout.strip()

    try:
        for tbl in MSSQL_TABLES:
            count_res = run_query(f"SELECT COUNT(*) FROM [{tbl}];")
            cnt_str = count_res.split("\n")[-1].strip()
            cnt = int(cnt_str) if cnt_str.isdigit() else 0
            print(f"  {YELLOW}▶ 테이블 [{tbl}]: {cnt}건{RESET}")

            if cnt > 0:
                if query_keyword:
                    if tbl == "users":
                        sql = f"SELECT user_id, email, nickname, role, status FROM [{tbl}] WHERE email LIKE '%{query_keyword}%' OR nickname LIKE '%{query_keyword}%';"
                    elif tbl == "cpp_server":
                        sql = f"SELECT server_id, server_ip, server_port, ws_port FROM [{tbl}] WHERE server_ip LIKE '%{query_keyword}%';"
                    elif tbl == "redis_server":
                        sql = f"SELECT redis_id, redis_ip, redis_port FROM [{tbl}] WHERE redis_ip LIKE '%{query_keyword}%';"
                    else:
                        sql = f"SELECT * FROM [{tbl}];"
                else:
                    sql = f"SELECT * FROM [{tbl}];"

                rows = run_query(sql)
                for line in rows.split("\n"):
                    print(f"    {line}")
            print()
    except Exception as e:
        print(f"  {RED}[ERROR] MS SQL 조회 실패: {e}{RESET}")


def search_elasticsearch(query_keyword: str = ""):
    print(f"{CYAN}[2/3] Elasticsearch 도큐먼트 조회 ({ES_USER}@{ES_HOST}, 인덱스: {ES_INDEX}){RESET}")
    auth_header = "Basic " + base64.b64encode(f"{ES_USER}:{ES_PASS}".encode()).decode()

    try:
        count_req = urllib.request.Request(f"{ES_HOST}/{ES_INDEX}/_count")
        count_req.add_header("Authorization", auth_header)
        with urllib.request.urlopen(count_req, timeout=5) as resp:
            data = json.loads(resp.read().decode())
            total = data.get("count", 0)
            print(f"  {YELLOW}▶ 인덱스 [{ES_INDEX}]: 총 {total}건{RESET}")

        if total > 0:
            if query_keyword:
                payload = json.dumps({
                    "size": 20,
                    "query": {
                        "multi_match": {
                            "query": query_keyword,
                            "fields": ["canvas-name^2", "description", "init-group"]
                        }
                    }
                }).encode()
            else:
                payload = json.dumps({"size": 20, "query": {"match_all": {}}}).encode()

            search_req = urllib.request.Request(
                f"{ES_HOST}/{ES_INDEX}/_search",
                data=payload,
                method="POST"
            )
            search_req.add_header("Authorization", auth_header)
            search_req.add_header("Content-Type", "application/json")

            with urllib.request.urlopen(search_req, timeout=10) as resp:
                s_data = json.loads(resp.read().decode())
                hits = s_data.get("hits", {}).get("hits", [])
                print(f"  일치한 도큐먼트 수: {len(hits)}건")
                for idx, hit in enumerate(hits, 1):
                    src = hit.get("_source", {})
                    cid = src.get("canvas-id", "N/A")
                    name = src.get("canvas-name", "N/A")
                    uid = src.get("admin-user-id", "N/A")
                    desc = src.get("description", "")
                    people = src.get("people", [])
                    print(f"    [{idx}] ID: {hit.get('_id')} | Canvas ID: {cid} | Name: {name} | Admin: {uid} | People: {people}")
                    if desc:
                        print(f"        Description: {desc}")
        print()
    except Exception as e:
        print(f"  {RED}[ERROR] Elasticsearch 조회 실패: {e}{RESET}\n")


def search_redis(query_keyword: str = ""):
    print(f"{CYAN}[3/3] Redis Stack 키 및 JSON 데이터 조회 ({REDIS_HOST}:{REDIS_PORT}){RESET}")

    def run_cli(*args) -> str:
        cluster_running = False
        for container in ("agora-redis-primary", "agora-redis-node"):
            cluster_state = subprocess.run(
                ["docker", "inspect", "-f", "{{.State.Running}}", container],
                capture_output=True, text=True
            )
            if cluster_state.stdout.strip() == "true":
                cluster_running = True
                break
        if cluster_running:
            cmd = ["bash", str(ROOT_DIR / "redis" / "redis-ha-cli.sh"), *args]
        else:
            cmd = [
                "docker", "exec",
                "-e", f"REDISCLI_AUTH={REDIS_ADMIN_PASS}",
                "agora-redis-stack",
                "redis-cli",
                *args,
            ]
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return res.stdout.strip()

    try:
        dbsize = run_cli("DBSIZE")
        print(f"  {YELLOW}▶ 전체 키 개수: {dbsize}건 (인덱스: {REDIS_INDEX_NAME}){RESET}")

        if query_keyword:
            search_res = run_cli("FT.SEARCH", REDIS_INDEX_NAME, query_keyword)
            print(f"  RediSearch 검색 결과: \"{query_keyword}\"")
            for line in search_res.split("\n"):
                print(f"    {line}")
        else:
            keys_raw = run_cli("KEYS", f"{REDIS_KEY_PREFIX}*")
            keys = [k.strip() for k in keys_raw.split("\n") if k.strip()]
            print(f"  발견된 캔버스 키: {len(keys)}건")

            for idx, k in enumerate(keys, 1):
                k_type = run_cli("TYPE", k)
                val = run_cli("JSON.GET", k) if "json" in k_type.lower() else run_cli("GET", k)
                try:
                    j_val = json.loads(val)
                    cid = j_val.get("canvas-id", "N/A")
                    name = j_val.get("canvas-name", "N/A")
                    uid = j_val.get("admin-user-id", "N/A")
                    print(f"    [{idx}] Key: {k} | Canvas ID: {cid} | Name: {name} | Admin: {uid}")
                except Exception:
                    print(f"    [{idx}] Key: {k} | Value: {val[:80]}")
        print()
    except Exception as e:
        print(f"  {RED}[ERROR] Redis 조회 실패: {e}{RESET}\n")


def main():
    parser = argparse.ArgumentParser(description="Agora All Storages Data Inspection & Search")
    parser.add_argument("-q", "--query", default="", help="모든 저장소 공통 검색 키워드")
    args = parser.parse_args()

    print(f"{CYAN}================================================================{RESET}")
    print(f"{CYAN}          Agora All Storages Data Inspection & Search           {RESET}")
    print(f"{CYAN}================================================================{RESET}")
    if args.query:
        print(f"  검색 키워드: \"{args.query}\"")
    else:
        print("  조회 모드: 전체 데이터 대시보드 출력")
    print(f"{CYAN}================================================================{RESET}")

    search_mssql(args.query)
    search_elasticsearch(args.query)
    search_redis(args.query)

    print(f"{GREEN}[SUCCESS] 모든 저장소 데이터 조회가 완료되었습니다.{RESET}\n")


if __name__ == "__main__":
    main()
