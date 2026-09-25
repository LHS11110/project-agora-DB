#!/usr/bin/env python3
"""
Storage integration checks for the configured SQL Server, Elasticsearch, and Redis endpoints.

The checks create uniquely named temporary records and remove them in finally blocks.
They require sqlcmd on PATH. SQL certificate verification is enabled unless the explicit
development-only DB_TRUST_SERVER_CERTIFICATE=true setting is provided.
"""

import base64
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

try:
    import redis as redis_lib
    from redis.sentinel import Sentinel
except ImportError:
    redis_lib = None
    Sentinel = None

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
RESET = "\033[0m"

ROOT_DIR = Path(__file__).resolve().parent.parent


def load_env_file(filepath):
    config = {}
    if filepath.exists():
        with filepath.open("r", encoding="utf-8") as stream:
            for raw_line in stream:
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                value = value.strip()
                if value and value[0] in ("'", '"'):
                    quote = value[0]
                    closing_quote = value.find(quote, 1)
                    if closing_quote >= 0:
                        value = value[1:closing_quote]
                else:
                    value = re.split(r"\s+#", value, maxsplit=1)[0].rstrip()
                config[key.strip()] = value
    return config


def configured(name, config, default=""):
    if name in os.environ:
        return os.environ[name]
    return config.get(name, default)


mssql_env = load_env_file(ROOT_DIR / "mssql" / ".env")
es_env = load_env_file(ROOT_DIR / "elasticsearch" / ".env")
redis_env = load_env_file(ROOT_DIR / "redis" / ".env")

mssql_raw_host = (
    os.environ.get("MSSQL_TEST_HOST")
    or os.environ.get("DB_HOST")
    or mssql_env.get("MSSQL_TEST_HOST")
    or mssql_env.get("MSSQL_HOST")
    or mssql_env.get("MSSQL_EXTERNAL_IP", "127.0.0.1")
)
MSSQL_HOST = "127.0.0.1" if mssql_raw_host in ("0.0.0.0", "::", "") else mssql_raw_host
MSSQL_PORT = (
    os.environ.get("MSSQL_TEST_PORT")
    or os.environ.get("DB_PORT")
    or mssql_env.get("MSSQL_TEST_PORT")
    or mssql_env.get("MSSQL_EXTERNAL_PORT")
    or mssql_env.get("MSSQL_PORT", "1433")
)
MSSQL_DB = configured("MSSQL_DB", mssql_env, "agora_db")
MSSQL_USER = configured("MSSQL_USER", mssql_env, "agora_user")
MSSQL_PASS = configured("MSSQL_PASSWORD", mssql_env, "")
MSSQL_TRUST_CERT = configured(
    "DB_TRUST_SERVER_CERTIFICATE", mssql_env, "false"
).lower() == "true"
MSSQL_ENCRYPT = configured("DB_ENCRYPT", mssql_env, "true").lower() != "false"
MSSQL_TABLE_USERS = configured("MSSQL_TABLE_USERS", mssql_env, "users")
MSSQL_TABLE_REDIS_SERVER = configured(
    "MSSQL_TABLE_REDIS_SERVER", mssql_env, "redis_server"
)
MSSQL_TABLE_CANVAS_INFO = configured(
    "MSSQL_TABLE_CANVAS_INFO",
    mssql_env,
    mssql_env.get("MSSQL_TABLE_CANVAS_CACHE", "canvas_info"),
)
MSSQL_TABLE_CPP_SERVER = configured("MSSQL_TABLE_CPP_SERVER", mssql_env, "cpp_server")

es_raw_host = (
    os.environ.get("ES_TEST_HOST")
    or os.environ.get("ES_HOST")
    or es_env.get("ES_TEST_HOST")
    or es_env.get("ES_EXTERNAL_IP", "127.0.0.1")
)
ES_HOST = "127.0.0.1" if es_raw_host in ("0.0.0.0", "::", "") else es_raw_host
ES_PORT = (
    os.environ.get("ES_TEST_PORT")
    or os.environ.get("ES_PORT")
    or es_env.get("ES_EXTERNAL_PORT")
    or es_env.get("ES_PORT", "9200")
)
ES_INDEX = configured("ES_INDEX", es_env, "canvas")
ES_USER = configured("ES_USER_NAME", es_env, "agora_user")
ES_PASS = configured("ES_USER_PASSWORD", es_env, "")
ES_TLS_ENABLED = configured("ES_HTTP_TLS_ENABLED", es_env, "false").lower() == "true"
ES_SCHEME = configured("ES_SCHEME", es_env, "https" if ES_TLS_ENABLED else "http").lower()
if ES_SCHEME not in ("http", "https"):
    raise ValueError("ES_SCHEME must be http or https")
ES_CA_CERT = configured("ES_CA_CERT", es_env, "")
if ES_HOST.startswith("http://") or ES_HOST.startswith("https://"):
    ES_URL = ES_HOST.rstrip("/")
    ES_URL_SCHEME = urllib.parse.urlsplit(ES_URL).scheme.lower()
else:
    es_url_host = f"[{ES_HOST}]" if ":" in ES_HOST and not ES_HOST.startswith("[") else ES_HOST
    ES_URL = f"{ES_SCHEME}://{es_url_host}:{ES_PORT}"
    ES_URL_SCHEME = ES_SCHEME
if ES_URL_SCHEME not in ("http", "https"):
    raise ValueError("Elasticsearch URL must use http or https")
if ES_TLS_ENABLED and ES_URL_SCHEME != "https":
    raise ValueError("ES_HTTP_TLS_ENABLED=true requires an HTTPS Elasticsearch URL")
ES_SSL_CONTEXT = (
    ssl.create_default_context(cafile=ES_CA_CERT or None)
    if ES_URL_SCHEME == "https"
    else None
)

redis_raw_host = (
    os.environ.get("REDIS_TEST_HOST")
    or os.environ.get("REDIS_HOST")
    or redis_env.get("REDIS_BIND_IP")
    or redis_env.get("REDIS_EXTERNAL_IP", "127.0.0.1")
)
REDIS_HOST = "127.0.0.1" if redis_raw_host in ("0.0.0.0", "::", "") else redis_raw_host
REDIS_PORT = (
    os.environ.get("REDIS_TEST_PORT")
    or os.environ.get("REDIS_PORT")
    or redis_env.get("REDIS_EXTERNAL_PORT")
    or redis_env.get("REDIS_PORT", "6379")
)
REDIS_USER = configured("REDIS_USER", redis_env, "agora_user")
REDIS_PASS = configured("REDIS_USER_PASSWORD", redis_env, "")
REDIS_INDEX_NAME = configured("REDIS_INDEX_NAME", redis_env, "idx:canvas")
REDIS_KEY_PREFIX = configured("REDIS_KEY_PREFIX", redis_env, "canvas:")
REDIS_SENTINELS = configured("REDIS_SENTINELS", redis_env, "")
REDIS_SENTINEL_MASTER_NAME = configured(
    "REDIS_SENTINEL_MASTER_NAME", redis_env, "agora-master"
)
REDIS_SENTINEL_USER = configured("REDIS_SENTINEL_USER", redis_env, "")
REDIS_SENTINEL_PASS = configured("REDIS_SENTINEL_PASSWORD", redis_env, "")

results = []


def record_test(name, passed, detail=""):
    status = f"[{GREEN}PASS{RESET}]" if passed else f"[{RED}FAIL{RESET}]"
    print(f"  {status} {name}")
    if not passed and detail:
        print(f"         {RED}원인: {detail}{RESET}")
    results.append((name, passed))


def sql_identifier(value):
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", value):
        raise ValueError(f"Unsupported SQL table name: {value!r}")
    return f"[{value}]"


def sql_server_target(host, port):
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    return f"tcp:{host},{port}"


def run_mssql_query(sql):
    if shutil.which("sqlcmd") is None:
        raise RuntimeError(
            "sqlcmd is required on PATH. Install Microsoft sqlcmd, then rerun this check."
        )
    command = [
        "sqlcmd",
        "-S",
        sql_server_target(MSSQL_HOST, MSSQL_PORT),
        "-U",
        MSSQL_USER,
        "-P",
        MSSQL_PASS,
        "-b",
        "-I",
        "-d",
        MSSQL_DB,
        "-W",
        "-h",
        "-1",
    ]
    if MSSQL_ENCRYPT:
        command.append("-N")
    if MSSQL_TRUST_CERT:
        command.append("-C")
    command.extend(["-Q", f"SET NOCOUNT ON; {sql}"])
    completed = subprocess.run(command, capture_output=True, text=True, check=True)
    return completed.stdout.strip()


def test_mssql():
    print(
        f"\n{YELLOW}[1/3] MS SQL Server CRUD/권한 테스트 "
        f"({MSSQL_USER}@{MSSQL_HOST}:{MSSQL_PORT}/{MSSQL_DB}){RESET}"
    )
    table_users = sql_identifier(MSSQL_TABLE_USERS)
    table_redis = sql_identifier(MSSQL_TABLE_REDIS_SERVER)
    table_canvas = sql_identifier(MSSQL_TABLE_CANVAS_INFO)
    table_cpp = sql_identifier(MSSQL_TABLE_CPP_SERVER)
    token = uuid.uuid4().hex
    email = f"test-{token}@agora.invalid"
    session_server_ip = f"test-session-{token}"
    crud_server_ip = f"test-crud-{token}"
    redis_ip = f"test-redis-{token}"
    port = 40000 + int(token[:4], 16) % 20000
    canvas_id = None
    mutations_started = False

    try:
        auth_info = run_mssql_query(
            "SELECT USER_NAME() + ':' + "
            "CONVERT(varchar(1), IS_ROLEMEMBER('agora_runtime')) + ':' + "
            "CONVERT(varchar(1), IS_ROLEMEMBER('db_owner'));"
        )
        expected_auth = f"{MSSQL_USER}:1:0"
        record_test(
            "런타임 계정은 agora_runtime DML 역할만 사용 (db_owner=0)",
            auth_info == expected_auth,
            auth_info,
        )

        table_list = ", ".join(
            "'" + name.replace("'", "''") + "'"
            for name in (
                MSSQL_TABLE_USERS,
                MSSQL_TABLE_REDIS_SERVER,
                MSSQL_TABLE_CANVAS_INFO,
                MSSQL_TABLE_CPP_SERVER,
            )
        )
        table_count = run_mssql_query(
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES "
            f"WHERE TABLE_TYPE='BASE TABLE' AND TABLE_NAME IN ({table_list});"
        )
        record_test("필수 SQL 테이블 4개 생성 확인", table_count == "4", table_count)

        probe = sql_identifier(f"__agora_runtime_ddl_probe_{token[:12]}")
        try:
            run_mssql_query(
                "BEGIN TRY BEGIN TRANSACTION; "
                f"CREATE TABLE dbo.{probe} (probe_id int NOT NULL); "
                "ROLLBACK TRANSACTION; END TRY "
                "BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW; END CATCH;"
            )
            record_test("런타임 계정의 스키마 변경 권한 차단", False, "CREATE TABLE unexpectedly succeeded")
        except subprocess.CalledProcessError as error:
            message = (error.stdout or "") + "\n" + (error.stderr or "")
            denied = "permission" in message.lower() and "denied" in message.lower()
            record_test(
                "런타임 계정의 스키마 변경 권한 차단",
                denied,
                message.strip() or str(error),
            )

        mutations_started = True
        run_mssql_query(
            f"INSERT INTO {table_cpp} (server_ip, server_port, ws_port, is_activated) "
            f"VALUES ('{session_server_ip}', '{port}', '{port + 1}', 1);"
        )
        run_mssql_query(
            f"INSERT INTO {table_users} "
            "(email, password_hash, nickname, tag_number, role, status) "
            f"VALUES ('{email}', 'dummy_hash', N'PyTester-{token[:8]}', 1234, 'ROLE_USER', 'ACTIVE');"
        )
        run_mssql_query(
            f"INSERT INTO [user_sessions] (user_id, is_accessed, cpp_server_id) "
            f"SELECT u.user_id, 1, s.server_id FROM {table_users} u "
            f"JOIN {table_cpp} s ON s.server_ip='{session_server_ip}' "
            f"WHERE u.email='{email}';"
        )
        user_count = run_mssql_query(
            f"SELECT COUNT(*) FROM {table_users} WHERE email='{email}';"
        )
        record_test("회원 및 세션 데이터 삽입 [Create]", user_count == "1", user_count)

        user_status = run_mssql_query(
            f"SELECT status FROM {table_users} WHERE email='{email}';"
        )
        record_test("회원 데이터 조회 [Read]", user_status == "ACTIVE", user_status)

        run_mssql_query(
            f"UPDATE {table_users} SET status='SUSPENDED' WHERE email='{email}';"
        )
        run_mssql_query(
            f"UPDATE [user_sessions] SET is_accessed=0 "
            f"WHERE user_id=(SELECT user_id FROM {table_users} WHERE email='{email}');"
        )
        user_status = run_mssql_query(
            f"SELECT status FROM {table_users} WHERE email='{email}';"
        )
        record_test("회원 및 세션 데이터 수정 [Update]", user_status == "SUSPENDED", user_status)

        run_mssql_query(
            f"INSERT INTO {table_redis} (redis_ip, redis_port, is_activated) "
            f"VALUES ('{redis_ip}', '{port + 2}', 1);"
        )
        canvas_id_text = run_mssql_query(
            f"INSERT INTO {table_canvas} (redis_id, is_cached) "
            f"SELECT redis_id, 0 FROM {table_redis} WHERE redis_ip='{redis_ip}'; "
            "SELECT CONVERT(varchar(20), SCOPE_IDENTITY());"
        )
        canvas_id = int(canvas_id_text)
        record_test("캔버스 배정 데이터 삽입 [Create]", canvas_id > 0, str(canvas_id))

        cached = run_mssql_query(
            f"SELECT CONVERT(varchar(1), is_cached) FROM {table_canvas} "
            f"WHERE canvas_id={canvas_id};"
        )
        record_test("캔버스 배정 데이터 조회 [Read]", cached == "0", cached)

        run_mssql_query(
            f"UPDATE {table_canvas} SET is_cached=1 WHERE canvas_id={canvas_id};"
        )
        cached = run_mssql_query(
            f"SELECT CONVERT(varchar(1), is_cached) FROM {table_canvas} "
            f"WHERE canvas_id={canvas_id};"
        )
        record_test("캔버스 배정 데이터 수정 [Update]", cached == "1", cached)

        run_mssql_query(
            f"INSERT INTO {table_cpp} (server_ip, server_port, ws_port, is_activated) "
            f"VALUES ('{crud_server_ip}', '{port + 3}', '{port + 4}', 1);"
        )
        cpp_port = run_mssql_query(
            f"SELECT server_port FROM {table_cpp} WHERE server_ip='{crud_server_ip}';"
        )
        record_test("C++ 서버 데이터 삽입·조회 [Create/Read]", cpp_port == str(port + 3), cpp_port)

        run_mssql_query(
            f"UPDATE {table_cpp} SET server_port='{port + 5}', is_activated=0 "
            f"WHERE server_ip='{crud_server_ip}';"
        )
        cpp_port = run_mssql_query(
            f"SELECT server_port FROM {table_cpp} WHERE server_ip='{crud_server_ip}';"
        )
        record_test("C++ 서버 데이터 수정 [Update]", cpp_port == str(port + 5), cpp_port)
    except Exception as error:
        record_test("MS SQL 연결 또는 CRUD 점검 실패", False, str(error))
    finally:
        if mutations_started:
            cleanup_sql = (
                f"DELETE FROM [user_sessions] WHERE user_id IN "
                f"(SELECT user_id FROM {table_users} WHERE email='{email}') "
                f"OR cpp_server_id IN (SELECT server_id FROM {table_cpp} "
                f"WHERE server_ip IN ('{session_server_ip}','{crud_server_ip}')); "
                f"DELETE FROM {table_canvas} WHERE redis_id IN "
                f"(SELECT redis_id FROM {table_redis} WHERE redis_ip='{redis_ip}') "
                f"OR cpp_server_id IN (SELECT server_id FROM {table_cpp} "
                f"WHERE server_ip IN ('{session_server_ip}','{crud_server_ip}')); "
                f"DELETE FROM {table_users} WHERE email='{email}'; "
                f"DELETE FROM {table_cpp} WHERE server_ip IN "
                f"('{session_server_ip}','{crud_server_ip}'); "
                f"DELETE FROM {table_redis} WHERE redis_ip='{redis_ip}';"
            )
            try:
                run_mssql_query(cleanup_sql)
                record_test("임시 SQL 테스트 데이터 정리", True)
            except Exception as error:
                record_test("임시 SQL 테스트 데이터 정리", False, str(error))


def es_request(path, method="GET", payload=None):
    auth_header = "Basic " + base64.b64encode(f"{ES_USER}:{ES_PASS}".encode()).decode()
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(f"{ES_URL}/{path.lstrip('/')}", data=data, method=method)
    request.add_header("Authorization", auth_header)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(
        request, timeout=10, context=ES_SSL_CONTEXT
    ) as response:
        return response.status, json.loads(response.read().decode())


def test_elasticsearch():
    print(
        f"\n{YELLOW}[2/3] Elasticsearch CRUD/Search 테스트 "
        f"({ES_USER}@{ES_URL}, 인덱스: {ES_INDEX}){RESET}"
    )
    token = uuid.uuid4().hex
    doc_id = f"test-{token}"
    doc_created = False
    canvas_id = int(token[:8], 16)

    try:
        _, data = es_request("/_security/_authenticate")
        authenticated = data.get("username") == ES_USER
        record_test("Elasticsearch 사용자 인증", authenticated, str(data.get("roles", [])))

        status, _ = es_request(f"/{ES_INDEX}")
        record_test("캔버스 인덱스 접근", status == 200)

        payload = {
            "canvas-id": canvas_id,
            "canvas-name": f"Agora Test Canvas {token[:8]}",
            "admin-user-id": 100,
            "description": f"temporary integration check {token}",
            "canvas-password-hash": "hash_secret_example",
            "people": [1, 2, 3, 4],
            "inner-group": {"group-name1": [1, 2], "group-name2": [3, 4]},
            "init-group": "group-name1",
        }
        _, created = es_request(
            f"/{ES_INDEX}/_create/{doc_id}?refresh=true", "PUT", payload
        )
        doc_created = created.get("result") == "created"
        record_test("Elasticsearch 문서 삽입 [Create]", doc_created, created.get("result", ""))

        _, found = es_request(f"/{ES_INDEX}/_doc/{doc_id}")
        found_ok = found.get("found", False) and found.get("_source", {}).get("canvas-id") == canvas_id
        record_test("Elasticsearch 문서 조회 [Read]", found_ok)

        _, search = es_request(
            f"/{ES_INDEX}/_search",
            "POST",
            {"query": {"ids": {"values": [doc_id]}}, "size": 1},
        )
        hits = search.get("hits", {}).get("hits", [])
        search_ok = any(hit.get("_id") == doc_id for hit in hits)
        record_test("Elasticsearch 문서 검색 [Search]", search_ok)

        _, updated = es_request(
            f"/{ES_INDEX}/_update/{doc_id}?refresh=true",
            "POST",
            {"doc": {"canvas-name": f"Agora Test Canvas Updated {token[:8]}"}},
        )
        record_test("Elasticsearch 문서 수정 [Update]", updated.get("result") == "updated")
    except Exception as error:
        record_test("Elasticsearch 연결 또는 CRUD 점검 실패", False, str(error))
    finally:
        if doc_created:
            try:
                _, deleted = es_request(f"/{ES_INDEX}/_doc/{doc_id}?refresh=true", "DELETE")
                record_test(
                    "임시 Elasticsearch 문서 정리",
                    deleted.get("result") == "deleted",
                    deleted.get("result", ""),
                )
            except Exception as error:
                record_test("임시 Elasticsearch 문서 정리", False, str(error))


def parse_sentinel_addresses(value):
    addresses = []
    for entry in value.split(","):
        entry = entry.strip()
        if not entry:
            continue
        if entry.startswith("[") and "]:" in entry:
            host, port = entry[1:].split("]:", 1)
        else:
            host, port = entry.rsplit(":", 1)
        addresses.append((host, int(port)))
    return addresses


def redis_result_text(value):
    if value is True:
        return "OK"
    if value is None:
        return ""
    return str(value)


def test_redis():
    print(
        f"\n{YELLOW}[3/3] RedisJSON/RediSearch CRUD/Scope 테스트 "
        f"({REDIS_USER}@{REDIS_HOST}:{REDIS_PORT}){RESET}"
    )
    token = uuid.uuid4().hex
    test_key = f"{REDIS_KEY_PREFIX}test-{token}"
    redis_client = None
    sentinel_client = None
    key_created = False

    try:
        if bool(REDIS_SENTINEL_USER) != bool(REDIS_SENTINEL_PASS):
            raise ValueError("REDIS_SENTINEL_USER and REDIS_SENTINEL_PASSWORD must be set together")

        if redis_lib is not None:
            common_options = {
                "decode_responses": True,
                "socket_connect_timeout": 5,
                "socket_timeout": 10,
            }
            if REDIS_SENTINELS:
                if Sentinel is None:
                    raise RuntimeError("redis-py Sentinel support is required when REDIS_SENTINELS is set")
                sentinel_options = {"socket_timeout": 5}
                if REDIS_SENTINEL_USER:
                    sentinel_options.update(
                        {"username": REDIS_SENTINEL_USER, "password": REDIS_SENTINEL_PASS}
                    )
                sentinel_client = Sentinel(
                    parse_sentinel_addresses(REDIS_SENTINELS),
                    sentinel_kwargs=sentinel_options,
                    **common_options,
                )
                redis_client = sentinel_client.master_for(
                    REDIS_SENTINEL_MASTER_NAME,
                    username=REDIS_USER,
                    password=REDIS_PASS,
                    **common_options,
                )
                print(
                    f"  - Sentinel primary discovery: {REDIS_SENTINELS} "
                    f"(master {REDIS_SENTINEL_MASTER_NAME})"
                )
            else:
                redis_client = redis_lib.Redis(
                    host=REDIS_HOST,
                    port=int(REDIS_PORT),
                    username=REDIS_USER,
                    password=REDIS_PASS,
                    **common_options,
                )

            ping = redis_client.ping()
            record_test("Redis ACL 인증 (PING)", ping is True)
            index_info = redis_client.execute_command("FT.INFO", REDIS_INDEX_NAME)
            record_test(
                f"RediSearch 인덱스({REDIS_INDEX_NAME}) 조회",
                REDIS_INDEX_NAME in str(index_info),
            )
        else:
            if REDIS_SENTINELS:
                raise RuntimeError(
                    "redis-py is required to test Sentinel endpoints; install the redis package"
                )
            if shutil.which("redis-cli"):
                command_prefix = [
                    "redis-cli",
                    "-h",
                    REDIS_HOST,
                    "-p",
                    str(REDIS_PORT),
                    "--user",
                    REDIS_USER,
                    "--no-auth-warning",
                    "--raw",
                ]
                env = os.environ.copy()
                env["REDISCLI_AUTH"] = REDIS_PASS
            else:
                command_prefix = [
                    "docker",
                    "exec",
                    "-e",
                    f"REDISCLI_AUTH={REDIS_PASS}",
                    "agora-redis-stack",
                    "redis-cli",
                    "--user",
                    REDIS_USER,
                    "--no-auth-warning",
                    "--raw",
                ]
                env = os.environ.copy()

            def run_redis_command(*args):
                completed = subprocess.run(
                    command_prefix + list(args),
                    capture_output=True,
                    text=True,
                    env=env,
                    check=True,
                )
                return completed.stdout.strip()

            ping = run_redis_command("PING")
            record_test("Redis ACL 인증 (PING)", ping == "PONG", ping)
            index_info = run_redis_command("FT.INFO", REDIS_INDEX_NAME)
            record_test(f"RediSearch 인덱스({REDIS_INDEX_NAME}) 조회", REDIS_INDEX_NAME in index_info)

        def execute(*args):
            if redis_client is not None:
                return redis_result_text(redis_client.execute_command(*args))
            return run_redis_command(*args)

        payload = {
            "canvas-id": int(token[:8], 16),
            "canvas-name": f"PyTest-{token[:8]}",
            "admin-user-id": 1000,
            "description": f"temporary integration check {token}",
            "canvas-password-hash": "hash_secret_example",
            "people": [1, 2, 3, 4],
            "inner-group": {"g1": [1, 2]},
            "init-group": "g1",
        }
        insert_result = execute("JSON.SET", test_key, "$", json.dumps(payload))
        key_created = insert_result == "OK"
        record_test("RedisJSON 데이터 삽입 [Create]", key_created, insert_result)

        json_result = execute("JSON.GET", test_key)
        record_test(
            "RedisJSON 데이터 조회 [Read]",
            "PyTest-" in json_result and "admin-user-id" in json_result,
            json_result,
        )

        search_result = execute(
            "FT.SEARCH",
            REDIS_INDEX_NAME,
            f"@canvas_id:[{payload['canvas-id']} {payload['canvas-id']}]",
        )
        record_test("RediSearch 데이터 조회 [Search]", test_key in search_result, search_result)

        update_result = execute(
            "JSON.SET", test_key, '$["admin-user-id"]', "2000"
        )
        record_test("RedisJSON 데이터 수정 [Update]", update_result == "OK", update_result)

        try:
            forbidden_result = execute("SET", f"other:{token}", "blocked")
            denied = "NOPERM" in forbidden_result.upper()
            record_test("타 네임스페이스 키 접근 차단", denied, forbidden_result)
        except Exception as error:
            message = str(error)
            denied = "noperm" in message.lower() or "permission" in message.lower()
            record_test("타 네임스페이스 키 접근 차단", denied, message)
    except Exception as error:
        record_test("Redis 연결 또는 CRUD 점검 실패", False, str(error))
    finally:
        if key_created:
            try:
                if redis_client is not None:
                    redis_client.delete(test_key)
                else:
                    run_redis_command("DEL", test_key)
                record_test("임시 Redis 키 정리", True)
            except Exception as error:
                record_test("임시 Redis 키 정리", False, str(error))
        if redis_client is not None:
            try:
                redis_client.close()
            except Exception:
                pass


def main():
    print(f"{CYAN}{'=' * 66}{RESET}")
    print(f"{CYAN} Agora Storage User Connection & CRUD Integration Checks {RESET}")
    print(f"{CYAN}{'=' * 66}{RESET}")

    test_mssql()
    test_elasticsearch()
    test_redis()

    passed = sum(1 for _, succeeded in results if succeeded)
    total = len(results)
    failed = total - passed
    print(f"\n{CYAN}{'=' * 66}{RESET}")
    print(f"  전체 검사: {total} | 성공: {GREEN}{passed}{RESET} | 실패: {RED}{failed}{RESET}")
    print(f"{CYAN}{'=' * 66}{RESET}")

    if failed:
        print(f"\n{RED}[FAILURE] 일부 저장소 점검이 실패했습니다.{RESET}")
        return 1
    print(f"\n{GREEN}[SUCCESS] 저장소 CRUD 및 권한 점검이 완료되었습니다.{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
