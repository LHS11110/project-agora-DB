#!/usr/bin/env python3
"""Prepare, validate, and apply Project Agora DB host configuration."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
import secrets
import shlex
import socket
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENV_FILES = {
    "mssql": ROOT / "mssql" / ".env",
    "redis": ROOT / "redis" / ".env",
    "elasticsearch": ROOT / "elasticsearch" / ".env",
}
SECRET_KEYS = {
    "MSSQL_SA_PASSWORD",
    "MSSQL_PASSWORD",
    "REDIS_PASSWORD",
    "REDIS_USER_PASSWORD",
    "REDIS_SENTINEL_PASSWORD",
    "ELASTIC_PASSWORD",
    "ES_USER_PASSWORD",
    "ES_LOG_USER_PASSWORD",
}
PLACEHOLDER = re.compile(r"(?i)(change[-_]me|replace[-_]this|<[^>]+>)")


class SetupError(RuntimeError):
    pass


def read_env(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    if not path.exists():
        return result
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            parsed = shlex.split(value, comments=False, posix=True)
            if len(parsed) != 1:
                raise SetupError(f"Invalid quoted environment setting: {key}")
            value = parsed[0]
        result[key] = value
    return result


def atomic_write(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp_path = Path(temp_name)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_path, path)
        os.chmod(path, mode)
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        temp_path.unlink(missing_ok=True)
        raise


def env_value(value: str) -> str:
    if any(character in value for character in ("\n", "\r", "$", "`")):
        raise SetupError("Generated environment settings cannot contain shell expansion or line breaks.")
    if not value or re.fullmatch(r"[A-Za-z0-9_./:@,+%!=-]+", value):
        return value
    return json.dumps(value, ensure_ascii=False)


def update_env_file(path: Path, desired: dict[str, str]) -> None:
    if path.is_symlink() or not path.is_file():
        raise SetupError(f"Missing or unsafe environment file: {path}")
    lines = path.read_text(encoding="utf-8").splitlines()
    seen: set[str] = set()
    output: list[str] = []
    for line in lines:
        match = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
        if match and match.group(1) in desired:
            key = match.group(1)
            if key not in seen:
                output.append(f"{key}={env_value(desired[key])}")
                seen.add(key)
            continue
        output.append(line)
    for key, value in desired.items():
        if key not in seen:
            output.append(f"{key}={env_value(value)}")
    if any("\n" in value or "\r" in value for value in desired.values()):
        raise SetupError(f"A setting for {path} contains an unsupported line break.")
    atomic_write(path, "\n".join(output) + "\n")


def generated_secret(key: str) -> str:
    token = hashlib.sha256(secrets.token_bytes(64)).hexdigest()
    # Both SQL logins use CHECK_POLICY and need three character classes.
    return f"A9!{token}" if key in {"MSSQL_SA_PASSWORD", "MSSQL_PASSWORD"} else token


def prepare(tls_dir: Path | None = None) -> None:
    missing = {service: not path.exists() for service, path in ENV_FILES.items()}
    if tls_dir is not None:
        tls_dir = tls_dir.expanduser().resolve()
        validate_config_path(tls_dir, "--tls-dir")
    for env_path in ENV_FILES.values():
        if env_path.is_symlink():
            raise SetupError(f"Refusing to modify symlinked environment file: {env_path}")
        example = env_path.with_name(".env.example")
        source_path = env_path if env_path.exists() else example
        if not source_path.is_file():
            raise SetupError(f"Environment template is missing: {example}")

        rewritten: list[str] = []
        for line in source_path.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                if key.strip() in SECRET_KEYS and PLACEHOLDER.search(value):
                    line = f"{key.strip()}={generated_secret(key.strip())}"
            rewritten.append(line)
        if env_path in (ENV_FILES["mssql"], ENV_FILES["elasticsearch"]) and not any(
            re.match(r"^\s*AGORA_NET_SUBNET\s*=", line) for line in rewritten
        ):
            rewritten.append("AGORA_NET_SUBNET=172.21.0.0/16")
        atomic_write(env_path, "\n".join(rewritten) + "\n")

    for directory in (
        ROOT / "elasticsearch" / "certs",
        ROOT / "elasticsearch" / "snapshots",
        ROOT / "mssql" / "tls",
    ):
        if directory.is_symlink():
            raise SetupError(f"Refusing to change permissions on symlinked directory: {directory}")
        directory.mkdir(parents=True, exist_ok=True, mode=0o750)
        os.chmod(directory, 0o750)

    for service, settings in {
        "mssql": {"MSSQL_TLS_ENABLED": "true", "DB_TRUST_SERVER_CERTIFICATE": "false"},
        "redis": {"REDIS_TLS_ENABLED": "true"},
        "elasticsearch": {"ES_HTTP_TLS_ENABLED": "true", "ES_SCHEME": "https"},
    }.items():
        update_env_file(ENV_FILES[service], settings)

    if missing["mssql"] or tls_dir is not None:
        sql_dir = tls_dir / "mssql" if tls_dir else ROOT / "mssql" / "tls"
        update_env_file(ENV_FILES["mssql"], {"MSSQL_TLS_CERTS_DIR": str(sql_dir), "SSL_CERT_FILE": str(sql_dir / "ca.crt")})
    if missing["redis"] or tls_dir is not None:
        redis_dir = tls_dir / "redis" if tls_dir else ROOT / "redis" / "tls" / "server"
        insight_dir = tls_dir / "internal" / "redis-insight" if tls_dir else ROOT / "redis" / "tls" / "insight"
        update_env_file(ENV_FILES["redis"], {
            "REDIS_TLS_CERTS_DIR": str(redis_dir),
            "REDIS_TLS_CA_CERT_HOST": str(redis_dir / "ca.crt"),
            "REDIS_INSIGHT_TLS_CERTS_DIR": str(insight_dir),
        })
    if missing["elasticsearch"] or tls_dir is not None:
        es_dir = tls_dir / "elasticsearch" if tls_dir else ROOT / "elasticsearch" / "certs"
        update_env_file(ENV_FILES["elasticsearch"], {
            "ES_TLS_CERTS_DIR": str(es_dir), "ES_CA_CERT": str(es_dir / "ca.crt"),
        })

    local_compose_subnets({service: read_env(path) for service, path in ENV_FILES.items()})
    print("Environment files prepared (0600); existing non-placeholder passwords preserved.")
    print("TLS and certificate verification are enabled. No certificates were generated.")
    print("Supply certificate/key/CA files, then validate before starting Docker.")


def local_compose_subnets(configs: dict[str, dict[str, str]]) -> tuple[ipaddress.IPv4Network, ipaddress.IPv4Network]:
    try:
        app_network = ipaddress.ip_network(
            configs["mssql"].get("AGORA_NET_SUBNET", "172.21.0.0/16"), strict=True
        )
        elastic_network = ipaddress.ip_network(
            configs["elasticsearch"].get("AGORA_NET_SUBNET", "172.21.0.0/16"), strict=True
        )
        redis_network = ipaddress.ip_network(
            configs["redis"].get("REDIS_HA_SUBNET", "172.20.0.0/16"), strict=True
        )
    except ValueError as error:
        raise SetupError("AGORA_NET_SUBNET and REDIS_HA_SUBNET must be valid CIDR networks.") from error
    if app_network.version != 4 or elastic_network.version != 4 or redis_network.version != 4:
        raise SetupError("Local Docker Compose networks must use IPv4 CIDRs.")
    if app_network != elastic_network:
        raise SetupError("mssql/.env and elasticsearch/.env must use the same AGORA_NET_SUBNET.")
    if app_network.overlaps(redis_network):
        raise SetupError("AGORA_NET_SUBNET and REDIS_HA_SUBNET overlap. Choose separate Docker subnets.")
    return app_network, redis_network


def repair_stale_local_network() -> None:
    """Remove only an unused Compose-owned app network with the old auto-assigned CIDR."""
    if shutil.which("docker") is None:
        return
    inspect = subprocess.run(
        ["docker", "network", "inspect", "agora-net", "--format", "{{json .}}"],
        capture_output=True, text=True,
    )
    if inspect.returncode:
        # Environment preparation also works before Docker is installed or started.
        return
    try:
        network = json.loads(inspect.stdout)
        existing_subnets = {
            item.get("Subnet") for item in network.get("IPAM", {}).get("Config", [])
            if item.get("Subnet")
        }
        desired_subnet = str(ipaddress.ip_network(
            read_env(ENV_FILES["mssql"]).get("AGORA_NET_SUBNET", "172.21.0.0/16"), strict=True
        ))
    except (json.JSONDecodeError, ValueError, TypeError) as error:
        raise SetupError("Could not inspect the existing Docker network agora-net safely.") from error
    if desired_subnet in existing_subnets:
        return

    project = network.get("Labels", {}).get("com.docker.compose.project")
    endpoints = network.get("Containers") or {}
    if endpoints:
        raise SetupError(
            "Docker network agora-net uses an old subnet and still has attached containers. "
            "Stop the backend with ./scripts/backend-docker.sh down, then run "
            "docker compose down (without -v) in this repository and retry prepare."
        )
    if project != "project-agora-db":
        raise SetupError(
            "Docker network agora-net has an unexpected owner and subnet. "
            "It was left untouched; inspect it before changing the network."
        )

    removed = subprocess.run(["docker", "network", "rm", "agora-net"], capture_output=True, text=True)
    if removed.returncode:
        raise SetupError("Could not remove the unused stale Docker network agora-net safely.")
    print("Removed the unused stale agora-net; Compose will recreate it with the configured subnet.")


def require_env_files() -> dict[str, dict[str, str]]:
    loaded: dict[str, dict[str, str]] = {}
    for service, path in ENV_FILES.items():
        if not path.is_file() or path.is_symlink():
            raise SetupError(f"Missing or unsafe environment file: {path}")
        mode = stat.S_IMODE(path.stat().st_mode)
        if mode & 0o077:
            raise SetupError(f"{path} must not be accessible by group or other users (current mode {mode:04o}).")
        values = read_env(path)
        if not values:
            raise SetupError(f"Environment file is empty: {path}")
        loaded[service] = values
    return loaded


def validate_secrets(configs: dict[str, dict[str, str]], production: bool) -> None:
    all_values: list[tuple[str, str]] = []
    missing: list[str] = []
    for service, values in configs.items():
        for key in sorted(SECRET_KEYS.intersection(values)):
            value = values[key]
            if not value or PLACEHOLDER.search(value):
                missing.append(f"{service}/.env:{key}")
                continue
            minimum = 32 if production else 16
            if len(value) < minimum:
                raise SetupError(f"{service}/.env:{key} must contain at least {minimum} characters.")
            if any(ch.isspace() for ch in value) or "\n" in value or "\r" in value:
                raise SetupError(f"{service}/.env:{key} contains unsupported whitespace.")
            if not re.fullmatch(r"[A-Za-z0-9!#%+=,.@_:-]+", value):
                raise SetupError(
                    f"{service}/.env:{key} contains characters unsupported by the shell-based DB tools; "
                    "use a random hexadecimal password (SQL passwords may start with A9!)."
                )
            all_values.append((f"{service}/{key}", value))
    expected = len(SECRET_KEYS)
    if missing or len(all_values) != expected:
        raise SetupError("Unconfigured secret values: " + ", ".join(missing or sorted(SECRET_KEYS)))
    for key in ("MSSQL_SA_PASSWORD", "MSSQL_PASSWORD"):
        password = configs["mssql"].get(key, "")
        classes = sum((any(c.isupper() for c in password), any(c.islower() for c in password),
                       any(c.isdigit() for c in password), any(not c.isalnum() for c in password)))
        if classes < 3:
            raise SetupError(f"{key} does not meet SQL Server password complexity requirements.")
    if production:
        seen: dict[str, str] = {}
        for name, value in all_values:
            if value in seen:
                raise SetupError(f"{name} must use a secret distinct from {seen[value]}.")
            if len(set(value)) < 12:
                raise SetupError(f"{name} must contain at least 12 distinct characters.")
            seen[value] = name


def compose_config(*args: str, env: dict[str, str] | None = None) -> None:
    command = ["docker", "compose", *args, "config", "--quiet"]
    completed = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True)
    if completed.returncode:
        detail = completed.stderr.strip() or "Compose configuration validation failed."
        raise SetupError(detail)


def validate_host(value: str, label: str, require_private: bool = True) -> None:
    if not value or value in {"0.0.0.0", "::", "localhost"}:
        raise SetupError(f"{label} must be a reachable private address or hostname.")
    try:
        addresses = [ipaddress.ip_address(value)]
    except ValueError:
        if "/" in value or " " in value:
            raise SetupError(f"{label} is not a valid IP address or hostname.")
        try:
            resolved = socket.getaddrinfo(value, None, type=socket.SOCK_STREAM)
        except OSError as error:
            raise SetupError(f"{label} could not be resolved on this host.") from error
        addresses = list({ipaddress.ip_address(item[4][0]) for item in resolved})
        if not addresses:
            raise SetupError(f"{label} did not resolve to an address.")
    for address in addresses:
        if address.is_loopback or address.is_link_local or address.is_multicast or address.is_unspecified:
            raise SetupError(f"{label} must not resolve to loopback, link-local, multicast, or wildcard addresses.")
        if require_private and not address.is_private:
            raise SetupError(f"{label} must resolve only to private addresses; got a non-private address.")


def validate_config_path(path: Path, label: str) -> None:
    if not path.is_absolute() or any(character in str(path) for character in ("\n", "\r", "$", "`", ",")):
        raise SetupError(f"{label} must be absolute and contain no line breaks, shell expansion or commas.")


def require_mounted_directory(value: str, label: str) -> Path:
    if not value:
        raise SetupError(f"Set {label} to an existing mounted durable-storage directory.")
    candidate = Path(value).expanduser()
    if not candidate.is_absolute():
        raise SetupError(f"{label} must be an absolute path.")
    try:
        mounted = candidate.resolve(strict=True)
    except OSError as error:
        raise SetupError(f"{label} does not exist: {candidate}") from error
    if not mounted.is_dir() or not os.path.ismount(mounted):
        raise SetupError(f"{label} must be an existing mount point: {mounted}")
    validate_config_path(mounted, label)
    return mounted


def require_absolute_directory(value: str, label: str) -> Path:
    candidate = Path(value).expanduser()
    if not candidate.is_absolute():
        raise SetupError(f"{label} must be an absolute host path.")
    if candidate.is_symlink():
        raise SetupError(f"{label} must not be a symlink: {candidate}")
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise SetupError(f"{label} does not exist: {candidate}") from error
    if not resolved.is_dir():
        raise SetupError(f"{label} must be a directory: {resolved}")
    validate_config_path(resolved, label)
    return resolved


def path_from_env(base: Path, value: str) -> Path:
    candidate = Path(value).expanduser()
    return candidate if candidate.is_absolute() else (base / candidate).resolve()


def verify_certificate(cert: Path, key: Path, ca: Path, hosts: list[str], label: str) -> None:
    for item in (cert, key, ca):
        if not item.is_file():
            raise SetupError(f"{label} certificate file is missing: {item}")
    verify = subprocess.run(["openssl", "verify", "-purpose", "sslserver", "-CAfile", str(ca), "-untrusted", str(cert), str(cert)], capture_output=True, text=True)
    if verify.returncode:
        raise SetupError(f"{label} certificate chain does not validate against its configured CA.")

    cert_pub = subprocess.run(
        ["openssl", "x509", "-in", str(cert), "-pubkey", "-noout"], capture_output=True, check=True
    ).stdout
    cert_der = subprocess.run(
        ["openssl", "pkey", "-pubin", "-outform", "DER"], input=cert_pub, capture_output=True, check=True
    ).stdout
    key_der = subprocess.run(
        ["openssl", "pkey", "-in", str(key), "-passin", "pass:", "-pubout", "-outform", "DER"], capture_output=True, check=True
    ).stdout
    if cert_der != key_der:
        raise SetupError(f"{label} certificate and private key do not match.")

    expiry = subprocess.run(["openssl", "x509", "-in", str(cert), "-checkend", "2592000", "-noout"], capture_output=True)
    if expiry.returncode:
        raise SetupError(f"{label} certificate expires within 30 days or is already expired.")

    # Parse SANs after verifying the chain/key/expiry above, without relying
    # on x509 -checkip/-checkhost; never fall back to an unverified CN.
    certificate_text = subprocess.run(
        ["openssl", "x509", "-in", str(cert), "-noout", "-text"],
        capture_output=True, text=True, check=True,
    ).stdout
    for host in dict.fromkeys(h for h in hosts if h):
        if not certificate_san_matches(certificate_text, host):
            raise SetupError(f"{label} certificate SAN does not match {host}.")


def certificate_san_matches(certificate_text: str, host: str) -> bool:
    match = re.search(r"X509v3 Subject Alternative Name:[^\n]*\n([^\n]+)", certificate_text)
    if not match:
        return False
    entries = [entry.strip() for entry in match.group(1).split(",")]
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        hostname = host.rstrip(".").encode("idna").decode("ascii").lower()
        for entry in entries:
            if not entry.startswith("DNS:"):
                continue
            pattern = entry[4:].rstrip(".").lower()
            if pattern == hostname:
                return True
            if pattern.startswith("*.") and pattern.count("*") == 1:
                labels = hostname.split(".")
                if len(labels) == len(pattern.split(".")) and ".".join(labels[1:]) == pattern[2:]:
                    return True
        return False
    for entry in entries:
        if entry.startswith("IP Address:"):
            try:
                if ipaddress.ip_address(entry[11:]) == address:
                    return True
            except ValueError:
                continue
    return False


def parse_sentinels(value: str) -> list[tuple[str, int]]:
    result: list[tuple[str, int]] = []
    for item in value.split(","):
        entry = item.strip()
        match = re.fullmatch(r"(\[[0-9A-Fa-f:.]+\]|[^:,\s]+):(\d+)", entry)
        if not match:
            raise SetupError("Sentinel seeds must be comma-separated host:26379 entries.")
        host = match.group(1).strip("[]")
        port = int(match.group(2))
        if port != 26379:
            raise SetupError("Production Sentinel seeds must use port 26379.")
        result.append((host, port))
    if len(result) != 3 or len(set(result)) != 3:
        raise SetupError("Provide exactly three distinct production Sentinel seeds.")
    return result


def validate(args: argparse.Namespace) -> None:
    configs = require_env_files()
    local_compose_subnets(configs)
    production = args.profile == "production"
    validate_secrets(configs, production)
    for service, key in (("mssql", "MSSQL_TLS_ENABLED"), ("redis", "REDIS_TLS_ENABLED"), ("elasticsearch", "ES_HTTP_TLS_ENABLED")):
        if configs[service].get(key, "true").lower() != "true":
            raise SetupError(f"TLS is required: {key}=true.")
    if configs["mssql"].get("DB_TRUST_SERVER_CERTIFICATE", "false").lower() != "false":
        raise SetupError("SQL certificate verification is required: DB_TRUST_SERVER_CERTIFICATE=false.")
    if configs["elasticsearch"].get("ES_SCHEME", "https") != "https":
        raise SetupError("Elasticsearch requires ES_SCHEME=https.")

    preflight_env = os.environ.copy()
    preflight_env.setdefault("MSSQL_NODE_HOSTNAME", "agora-check")
    preflight_env.setdefault("MSSQL_NODE_BIND_IP", "10.0.0.10")
    preflight_env.setdefault("REDIS_COMPOSE_PROJECT", "agora-check")
    preflight_env.setdefault("REDIS_NODE_HOSTNAME", "agora-check")
    preflight_env.setdefault("REDIS_NODE_ANNOUNCE_IP", "10.0.0.10")
    preflight_env.setdefault("REDIS_SENTINEL_MASTER_HOST", "10.0.0.10")
    for compose_args in (
        ("-f", "docker-compose.yml"),
        ("--env-file", "mssql/.env", "-f", "mssql/docker-compose.yml"),
        ("--env-file", "redis/.env", "-p", "agora-redis-ha", "-f", "redis/docker-compose.sentinel.yml"),
        ("--env-file", "mssql/.env", "-f", "mssql/cluster/docker-compose.node.yml"),
        ("--env-file", "redis/.env", "-p", "agora-check", "-f", "redis/docker-compose.ha-node.yml"),
        ("--env-file", "elasticsearch/.env", "-f", "elasticsearch/docker-compose.yml"),
    ):
        compose_config(*compose_args, env=preflight_env)

    if not production:
        sql = configs["mssql"]
        sql_dir = path_from_env(ROOT / "mssql", sql.get("MSSQL_TLS_CERTS_DIR", "./tls"))
        verify_certificate(sql_dir / "server.crt", sql_dir / "server.key", sql_dir / "ca.crt",
                           ["agora-mssql", "mssql", "localhost", sql.get("MSSQL_EXTERNAL_IP", "127.0.0.1")], "SQL Server")
        elastic = configs["elasticsearch"]
        if elastic.get("ES_HTTP_TLS_ENABLED", "false").lower() == "true":
            cert_dir = path_from_env(ROOT / "elasticsearch", elastic.get("ES_TLS_CERTS_DIR", "./certs"))
            verify_certificate(cert_dir / "http.crt", cert_dir / "http.key", cert_dir / "ca.crt",
                               ["agora-elasticsearch", "localhost", elastic.get("ES_EXTERNAL_IP", "127.0.0.1")], "Elasticsearch")
        redis = configs["redis"]
        if redis.get("REDIS_TLS_ENABLED", "false").lower() == "true":
            redis_dir = path_from_env(ROOT / "redis", redis.get("REDIS_TLS_CERTS_DIR", "./tls/server")).resolve()
            validate_config_path(redis_dir, "REDIS_TLS_CERTS_DIR")
            verify_certificate(redis_dir / "server.crt", redis_dir / "server.key", redis_dir / "ca.crt",
                               [redis.get(key, default) for key, default in (("REDIS_PRIMARY_IP", "172.20.0.2"), ("REDIS_REPLICA_1_IP", "172.20.0.7"), ("REDIS_REPLICA_2_IP", "172.20.0.5"), ("REDIS_SENTINEL_1_IP", "172.20.0.6"), ("REDIS_SENTINEL_2_IP", "172.20.0.3"), ("REDIS_SENTINEL_3_IP", "172.20.0.4"))], "Redis/Sentinel")
            host_ca_setting = redis.get("REDIS_TLS_CA_CERT_HOST", "")
            if not host_ca_setting or not Path(host_ca_setting).is_absolute():
                raise SetupError("Set REDIS_TLS_CA_CERT_HOST to an absolute CA path readable by BE clients.")
            host_ca = Path(host_ca_setting)
            validate_config_path(host_ca, "REDIS_TLS_CA_CERT_HOST")
            if not host_ca.is_file():
                raise SetupError("REDIS_TLS_CA_CERT_HOST must point to an existing CA certificate.")
            result = subprocess.run(["openssl", "verify", "-CAfile", str(host_ca),
                                     str(redis_dir / "server.crt")], capture_output=True, text=True)
            if result.returncode:
                raise SetupError("REDIS_TLS_CA_CERT_HOST does not validate the Redis/Sentinel certificate.")
        print("Development configuration and Compose files are valid.")
        return

    mssql = configs["mssql"]
    redis = configs["redis"]
    elastic = configs["elasticsearch"]
    if mssql.get("MSSQL_TLS_ENABLED", "false").lower() != "true":
        raise SetupError("Production requires MSSQL_TLS_ENABLED=true.")
    if mssql.get("DB_TRUST_SERVER_CERTIFICATE", "false").lower() == "true":
        raise SetupError("Production must verify the SQL Server certificate; DB_TRUST_SERVER_CERTIFICATE must be false.")
    if elastic.get("ES_HTTP_TLS_ENABLED", "false").lower() != "true":
        raise SetupError("Production requires ES_HTTP_TLS_ENABLED=true.")
    if elastic.get("ES_SCHEME", "").lower() != "https":
        raise SetupError("Production requires ES_SCHEME=https.")
    if not redis.get("REDIS_SENTINEL_USER") or not redis.get("REDIS_SENTINEL_PASSWORD"):
        raise SetupError("Production requires a dedicated Redis Sentinel reader account.")
    if redis.get("REDIS_TLS_ENABLED", "false").lower() != "true":
        raise SetupError("Production requires verified TLS for Redis nodes, replication, and Sentinel.")

    sql_host = (args.sql_host or os.environ.get("AGORA_DB_HOST") or mssql.get("MSSQL_MANAGEMENT_HOST", "")
                or mssql.get("MSSQL_EXTERNAL_IP", ""))
    es_host = args.es_host or os.environ.get("AGORA_ES_HOST") or elastic.get("ES_EXTERNAL_IP", "")
    validate_host(sql_host, "SQL listener")
    validate_host(es_host, "Elasticsearch endpoint")
    private_ipv4(mssql.get("MSSQL_EXTERNAL_IP", ""), "SQL bind address")
    private_ipv4(elastic.get("ES_EXTERNAL_IP", ""), "Elasticsearch bind address")
    private_node_ip(redis.get("REDIS_EXTERNAL_IP", ""), "Redis client address")

    seeds = (args.redis_sentinels or os.environ.get("AGORA_REDIS_SENTINELS", "")
             or redis.get("REDIS_SENTINELS", ""))
    for host, _ in parse_sentinels(seeds):
        validate_host(host, "Redis Sentinel seed", require_private=True)

    backup_root = require_mounted_directory(args.backup_root or os.environ.get("AGORA_BACKUP_ROOT", ""),
                                            "--backup-root / AGORA_BACKUP_ROOT")
    snapshot_dir = path_from_env(ROOT / "elasticsearch", elastic.get("ES_SNAPSHOT_HOST_DIR", "./snapshots"))
    snapshot_dir = snapshot_dir.resolve()
    validate_config_path(snapshot_dir, "ES_SNAPSHOT_HOST_DIR")
    if not snapshot_dir.is_dir() or not snapshot_dir.is_relative_to(backup_root):
        raise SetupError("ES_SNAPSHOT_HOST_DIR must be an existing directory inside the mounted backup root.")

    sql_dir = path_from_env(ROOT / "mssql", mssql.get("MSSQL_TLS_CERTS_DIR", "./tls")).resolve()
    es_dir = path_from_env(ROOT / "elasticsearch", elastic.get("ES_TLS_CERTS_DIR", "./certs")).resolve()
    validate_config_path(sql_dir, "MSSQL_TLS_CERTS_DIR")
    validate_config_path(es_dir, "ES_TLS_CERTS_DIR")
    verify_certificate(sql_dir / "server.crt", sql_dir / "server.key", sql_dir / "ca.crt",
                       [sql_host, args.sql_node_hostname or os.environ.get("MSSQL_NODE_HOSTNAME", "")], "SQL Server")
    verify_certificate(es_dir / "http.crt", es_dir / "http.key", es_dir / "ca.crt", [es_host], "Elasticsearch")
    redis_dir = path_from_env(ROOT / "redis", redis.get("REDIS_TLS_CERTS_DIR", "./tls/server")).resolve()
    validate_config_path(redis_dir, "REDIS_TLS_CERTS_DIR")
    verify_certificate(redis_dir / "server.crt", redis_dir / "server.key", redis_dir / "ca.crt",
                       [redis.get("REDIS_EXTERNAL_IP", "")], "Redis/Sentinel")
    redis_ca_setting = redis.get("REDIS_TLS_CA_CERT_HOST", "")
    if not redis_ca_setting or not Path(redis_ca_setting).is_absolute():
        raise SetupError("Set REDIS_TLS_CA_CERT_HOST to an absolute host path for BE Redis TLS verification.")
    host_redis_ca = Path(redis_ca_setting)
    validate_config_path(host_redis_ca, "REDIS_TLS_CA_CERT_HOST")
    if not host_redis_ca.is_file():
        raise SetupError("Set REDIS_TLS_CA_CERT_HOST to an existing CA certificate file.")
    redis_ca_check = subprocess.run(
        ["openssl", "verify", "-CAfile", str(host_redis_ca), str(redis_dir / "server.crt")],
        capture_output=True, text=True,
    )
    if redis_ca_check.returncode:
        raise SetupError("Redis REDIS_TLS_CA_CERT_HOST does not validate the configured Redis certificate.")
    es_ca_setting = elastic.get("ES_CA_CERT", "")
    if not es_ca_setting or not Path(es_ca_setting).is_absolute():
        raise SetupError("Set Elasticsearch ES_CA_CERT to an absolute host path for DB management scripts.")
    host_es_ca = Path(es_ca_setting)
    validate_config_path(host_es_ca, "ES_CA_CERT")
    if not host_es_ca.is_file():
        raise SetupError("Set Elasticsearch ES_CA_CERT to an existing host path for DB management scripts.")
    ca_check = subprocess.run(["openssl", "verify", "-CAfile", str(host_es_ca), str(es_dir / "http.crt")],
                              capture_output=True, text=True)
    if ca_check.returncode:
        raise SetupError("Elasticsearch ES_CA_CERT does not validate the configured HTTPS certificate.")
    print("Production credentials, private endpoints, Redis/Sentinel and SQL/ES TLS chains, SANs, and Compose syntax are valid.")
    print("Firewall rules, host separation, Pacemaker quorum/fencing, and restore exercises still require target infrastructure.")


def configure_production(args: argparse.Namespace) -> None:
    configs = require_env_files()
    validate_secrets(configs, production=True)
    if not re.fullmatch(r"[A-Za-z0-9-]{1,15}", args.sql_node_hostname):
        raise SetupError("--sql-node-hostname must be a SQL Server name (15 characters maximum).")
    validate_host(args.sql_host, "SQL AG listener")
    private_ipv4(args.sql_bind_ip, "--sql-bind-ip")
    validate_host(args.es_host, "Elasticsearch endpoint")
    if not 1 <= args.sql_port <= 65535:
        raise SetupError("--sql-port must be between 1 and 65535.")
    private_ipv4(args.es_bind_ip, "--es-bind-ip")
    private_node_ip(args.redis_primary_ip, "--redis-primary-ip")
    sentinels = parse_sentinels(args.redis_sentinels)
    for host, _ in sentinels:
        validate_host(host, "Redis Sentinel seed", require_private=True)

    sql_dir = require_absolute_directory(args.sql_cert_dir, "--sql-cert-dir")
    es_dir = require_absolute_directory(args.es_cert_dir, "--es-cert-dir")
    redis_dir = require_absolute_directory(args.redis_cert_dir, "--redis-cert-dir")
    backup_root = require_mounted_directory(args.backup_root, "--backup-root")
    snapshot_dir = Path(args.es_snapshot_dir).expanduser() if args.es_snapshot_dir else backup_root / "elasticsearch-snapshots"
    if not snapshot_dir.is_absolute():
        raise SetupError("--es-snapshot-dir must be an absolute path.")
    if snapshot_dir.is_symlink():
        raise SetupError("--es-snapshot-dir must not be a symlink.")
    snapshot_dir = snapshot_dir.resolve()
    if not snapshot_dir.is_relative_to(backup_root):
        raise SetupError("--es-snapshot-dir must be inside --backup-root.")
    validate_config_path(snapshot_dir, "--es-snapshot-dir")

    verify_certificate(sql_dir / "server.crt", sql_dir / "server.key", sql_dir / "ca.crt",
                       [args.sql_host, args.sql_node_hostname], "SQL Server")
    verify_certificate(es_dir / "http.crt", es_dir / "http.key", es_dir / "ca.crt",
                       [args.es_host], "Elasticsearch")
    verify_certificate(redis_dir / "server.crt", redis_dir / "server.key", redis_dir / "ca.crt",
                       [args.redis_primary_ip], "Redis/Sentinel")

    snapshot_dir.mkdir(parents=True, exist_ok=True, mode=0o750)
    os.chmod(snapshot_dir, 0o750)
    update_env_file(ENV_FILES["mssql"], {
        "MSSQL_EXTERNAL_IP": args.sql_bind_ip,
        "MSSQL_MANAGEMENT_HOST": args.sql_host,
        "MSSQL_MANAGEMENT_PORT": str(args.sql_port),
        "DB_TRUST_SERVER_CERTIFICATE": "false",
        "MSSQL_TLS_ENABLED": "true",
        "MSSQL_TLS_CERTS_DIR": str(sql_dir),
        "MSSQL_TLS_CERTIFICATE": "/run/secrets/mssql-tls/server.crt",
        "MSSQL_TLS_KEY": "/run/secrets/mssql-tls/server.key",
    })
    update_env_file(ENV_FILES["redis"], {
        "REDIS_EXTERNAL_IP": args.redis_primary_ip,
        "REDIS_SENTINELS": ",".join(f"{host}:{port}" for host, port in sentinels),
        "REDIS_TLS_ENABLED": "true",
        "REDIS_TLS_CERTS_DIR": str(redis_dir),
        "REDIS_TLS_CERTIFICATE": "/run/secrets/redis-tls/server.crt",
        "REDIS_TLS_KEY": "/run/secrets/redis-tls/server.key",
        "REDIS_TLS_CA_CERT": "/run/secrets/redis-tls/ca.crt",
        "REDIS_TLS_CA_CERT_HOST": str(redis_dir / "ca.crt"),
    })
    update_env_file(ENV_FILES["elasticsearch"], {
        "ES_EXTERNAL_IP": args.es_bind_ip,
        "ES_SCHEME": "https",
        "ES_HTTP_TLS_ENABLED": "true",
        "ES_TLS_CERTS_DIR": str(es_dir),
        "ES_TLS_CERTIFICATE": "/usr/share/elasticsearch/config/certs/http.crt",
        "ES_TLS_KEY": "/usr/share/elasticsearch/config/certs/http.key",
        "ES_CA_CERT": str(es_dir / "ca.crt"),
        "ES_SNAPSHOT_HOST_DIR": str(snapshot_dir),
    })

    validate(argparse.Namespace(
        profile="production", sql_host=args.sql_host, es_host=args.es_host,
        sql_node_hostname=args.sql_node_hostname, redis_sentinels=args.redis_sentinels,
        backup_root=str(backup_root),
    ))
    print("Production TLS, private endpoints, and durable Elasticsearch snapshot settings were written to service .env files.")
    print("Environment files remain mode 0600; BE connection settings are updated separately with sync-backend.")


def sync_backend(args: argparse.Namespace) -> None:
    configs = require_env_files()
    validate_secrets(configs, production=True)
    mssql = configs["mssql"]
    redis = configs["redis"]
    elastic = configs["elasticsearch"]

    if mssql.get("MSSQL_TLS_ENABLED", "false").lower() != "true" or mssql.get("DB_TRUST_SERVER_CERTIFICATE", "false").lower() == "true":
        raise SetupError("Backend synchronization requires verified SQL TLS configuration.")
    if elastic.get("ES_HTTP_TLS_ENABLED", "false").lower() != "true":
        raise SetupError("Backend synchronization requires Elasticsearch HTTPS.")
    if redis.get("REDIS_TLS_ENABLED", "false").lower() != "true":
        raise SetupError("Backend synchronization requires verified Redis/Sentinel TLS.")
    sentinels = parse_sentinels(args.redis_sentinels)
    if not 1 <= args.db_port <= 65535 or not 1 <= args.es_port <= 65535:
        raise SetupError("Backend SQL and Elasticsearch ports must be between 1 and 65535.")
    validate_host(args.db_host, "SQL listener")
    validate_host(args.es_host, "Elasticsearch endpoint")
    for host, _ in sentinels:
        validate_host(host, "Redis Sentinel seed", require_private=True)
    if not Path(args.es_ca_cert).is_absolute():
        raise SetupError("--es-ca-cert must be the absolute CA path available inside the BE runtime.")
    if not Path(args.redis_ca_cert).is_absolute():
        raise SetupError("--redis-ca-cert must be the absolute CA path available inside the BE runtime.")
    if not Path(args.db_freetds_conf).is_absolute():
        raise SetupError("--db-freetds-conf must be the absolute FreeTDS config path available to C++.")
    validate_config_path(Path(args.es_ca_cert), "--es-ca-cert")
    validate_config_path(Path(args.redis_ca_cert), "--redis-ca-cert")
    validate_config_path(Path(args.db_freetds_conf), "--db-freetds-conf")
    sql_dir = path_from_env(ROOT / "mssql", mssql.get("MSSQL_TLS_CERTS_DIR", "./tls"))
    es_dir = path_from_env(ROOT / "elasticsearch", elastic.get("ES_TLS_CERTS_DIR", "./certs"))
    redis_dir = path_from_env(ROOT / "redis", redis.get("REDIS_TLS_CERTS_DIR", "./tls/server"))
    verify_certificate(sql_dir / "server.crt", sql_dir / "server.key", sql_dir / "ca.crt", [args.db_host], "SQL Server")
    verify_certificate(es_dir / "http.crt", es_dir / "http.key", es_dir / "ca.crt", [args.es_host], "Elasticsearch")
    verify_certificate(redis_dir / "server.crt", redis_dir / "server.key", redis_dir / "ca.crt",
                       [redis.get("REDIS_EXTERNAL_IP", "")], "Redis/Sentinel")
    redis_ca = Path(args.redis_ca_cert)
    validate_config_path(redis_ca, "--redis-ca-cert")
    if not redis_ca.is_file():
        raise SetupError("--redis-ca-cert must be a readable CA certificate file in the BE runtime.")
    redis_ca_check = subprocess.run(
        ["openssl", "verify", "-CAfile", str(redis_ca), str(redis_dir / "server.crt")],
        capture_output=True, text=True,
    )
    if redis_ca_check.returncode:
        raise SetupError("--redis-ca-cert does not validate the configured Redis/Sentinel certificate.")

    backend_input = Path(args.backend_env).expanduser()
    if backend_input.is_symlink():
        raise SetupError(f"Backend .env must not be a symlink: {backend_input}")
    backend_path = backend_input.resolve()
    if not backend_path.is_file():
        raise SetupError(f"Backend .env must already exist: {backend_path}")
    desired = {
        "DB_HOST": args.db_host,
        "DB_PORT": str(args.db_port),
        "DB_NAME": mssql.get("MSSQL_DB", "agora_db"),
        "DB_USER": mssql.get("MSSQL_USER", "agora_user"),
        "DB_PASSWORD": mssql["MSSQL_PASSWORD"],
        "DB_MULTI_SUBNET_FAILOVER": "true" if args.multi_subnet else "false",
        "DB_ENCRYPT": "true",
        "DB_TRUST_SERVER_CERTIFICATE": "false",
        "DB_FREETDS_CONF": args.db_freetds_conf,
        "ES_HOST": args.es_host,
        "ES_PORT": str(args.es_port),
        "ES_SCHEME": "https",
        "ES_CA_CERT": args.es_ca_cert,
        "ES_INDEX": elastic.get("ES_INDEX", "canvas"),
        "ES_SEARCH_INDEX": elastic.get("ES_SEARCH_INDEX", "canvas-search"),
        "ES_USER_NAME": elastic.get("ES_USER_NAME", "agora_user"),
        "ES_USER_PASSWORD": elastic["ES_USER_PASSWORD"],
        "ES_LOG_INDEX": elastic.get("ES_LOG_INDEX", "agora-logs"),
        "ES_LOG_USER_NAME": elastic.get("ES_LOG_USER_NAME", "agora_log_writer"),
        "ES_LOG_USER_PASSWORD": elastic["ES_LOG_USER_PASSWORD"],
        "REDIS_USER": redis.get("REDIS_USER", "agora_user"),
        "REDIS_USER_PASSWORD": redis["REDIS_USER_PASSWORD"],
        "REDIS_SENTINELS": ",".join(
            f"[{host}]:{port}" if ":" in host else f"{host}:{port}" for host, port in sentinels
        ),
        "REDIS_SENTINEL_MASTER_NAME": redis.get("REDIS_SENTINEL_MASTER_NAME", "agora-master"),
        "REDIS_SENTINEL_USER": redis["REDIS_SENTINEL_USER"],
        "REDIS_SENTINEL_PASSWORD": redis["REDIS_SENTINEL_PASSWORD"],
        "REDIS_TLS_ENABLED": "true",
        "REDIS_TLS_CA_CERT": args.redis_ca_cert,
    }
    if any("\n" in value or "\r" in value for value in desired.values()):
        raise SetupError("A backend setting contains an unsupported line break.")

    lines = backend_path.read_text(encoding="utf-8").splitlines()
    seen: set[str] = set()
    output: list[str] = []
    for line in lines:
        match = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
        if match and match.group(1) in desired:
            key = match.group(1)
            if key not in seen:
                output.append(f"{key}={env_value(desired[key])}")
                seen.add(key)
            continue
        output.append(line)
    for key, value in desired.items():
        if key not in seen:
            output.append(f"{key}={env_value(value)}")
    atomic_write(backend_path, "\n".join(output) + "\n")
    print(f"Updated {len(desired)} DB-related settings in {backend_path}; unrelated backend settings were preserved.")
    print("Backend .env permissions are now 0600. Secret values were not displayed.")


def private_node_ip(value: str, label: str) -> None:
    try:
        address = ipaddress.ip_address(value)
    except ValueError as error:
        raise SetupError(f"{label} must be a literal private IP address.") from error
    if not address.is_private or address.is_loopback or address.is_link_local or address.is_multicast:
        raise SetupError(f"{label} must be a private unicast IP address.")


def private_ipv4(value: str, label: str) -> None:
    private_node_ip(value, label)
    if ipaddress.ip_address(value).version != 4:
        raise SetupError(f"{label} must be IPv4 because the Compose port mapping uses short syntax.")


def deploy_sql_node(args: argparse.Namespace) -> None:
    configs = require_env_files()
    validate_secrets(configs, production=True)
    if configs["mssql"].get("MSSQL_TLS_ENABLED", "false").lower() != "true":
        raise SetupError("The SQL AG node must start with MSSQL_TLS_ENABLED=true.")
    hostname = os.environ.get("MSSQL_NODE_HOSTNAME", "")
    bind_ip = os.environ.get("MSSQL_NODE_BIND_IP", "")
    pid = os.environ.get("MSSQL_NODE_PID", "Standard")
    if not re.fullmatch(r"[A-Za-z0-9-]{1,15}", hostname):
        raise SetupError("Set MSSQL_NODE_HOSTNAME to a unique SQL Server name (15 characters maximum).")
    private_ipv4(bind_ip, "MSSQL_NODE_BIND_IP")
    if pid not in {"Standard", "Express"}:
        raise SetupError("MSSQL_NODE_PID must be Standard or Express.")
    tls_dir = path_from_env(ROOT / "mssql", configs["mssql"].get("MSSQL_TLS_CERTS_DIR", "./tls"))
    verify_certificate(tls_dir / "server.crt", tls_dir / "server.key", tls_dir / "ca.crt",
                       [hostname, configs["mssql"].get("MSSQL_MANAGEMENT_HOST", "")], "SQL Server")
    env = os.environ.copy()
    env["MSSQL_NODE_TLS_CERTS_DIR"] = str(tls_dir.resolve())
    compose_config("--env-file", "mssql/.env", "-f", "mssql/cluster/docker-compose.node.yml", env=env)
    project = os.environ.get("MSSQL_COMPOSE_PROJECT", f"agora-mssql-{hostname.lower()}")
    subprocess.run(["docker", "compose", "--env-file", "mssql/.env", "-p", project,
                    "-f", "mssql/cluster/docker-compose.node.yml", "up", "-d"], cwd=ROOT, env=env, check=True)
    print("SQL Server node is running. AG creation, Pacemaker quorum, fencing, and listener setup remain separate host operations.")


def deploy_redis_node(args: argparse.Namespace) -> None:
    configs = require_env_files()
    validate_secrets(configs, production=True)
    env = os.environ.copy()
    role = env.get("REDIS_NODE_ROLE", "")
    hostname = env.get("REDIS_NODE_HOSTNAME", "")
    announce_ip = env.get("REDIS_NODE_ANNOUNCE_IP", "")
    master_host = env.get("REDIS_SENTINEL_MASTER_HOST", "")
    if role not in {"primary", "replica"}:
        raise SetupError("Set REDIS_NODE_ROLE=primary or replica.")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", hostname):
        raise SetupError("Set a unique REDIS_NODE_HOSTNAME.")
    private_node_ip(announce_ip, "REDIS_NODE_ANNOUNCE_IP")
    private_node_ip(env.get("REDIS_NODE_BIND_IP", announce_ip), "REDIS_NODE_BIND_IP")
    sentinel_bind_ip = env.get("REDIS_SENTINEL_BIND_IP", announce_ip)
    private_node_ip(sentinel_bind_ip, "REDIS_SENTINEL_BIND_IP")
    validate_host(master_host, "REDIS_SENTINEL_MASTER_HOST", require_private=True)
    primary_host = env.get("REDIS_NODE_PRIMARY_HOST", "")
    if role == "primary" and primary_host:
        raise SetupError("The initial primary must not set REDIS_NODE_PRIMARY_HOST.")
    if role == "replica" and not primary_host:
        raise SetupError("A replica requires REDIS_NODE_PRIMARY_HOST pointing at the initial primary.")
    if primary_host:
        validate_host(primary_host, "REDIS_NODE_PRIMARY_HOST")
    if not configs["redis"].get("REDIS_SENTINEL_USER") or not configs["redis"].get("REDIS_SENTINEL_PASSWORD"):
        raise SetupError("Each production Redis node requires the dedicated Sentinel reader account.")
    if configs["redis"].get("REDIS_TLS_ENABLED", "false").lower() != "true":
        raise SetupError("Each production Redis node requires Redis/Sentinel TLS.")
    tls_dir = require_absolute_directory(
        env.get("REDIS_TLS_CERTS_DIR", configs["redis"].get("REDIS_TLS_CERTS_DIR", "")),
        "REDIS_TLS_CERTS_DIR",
    )
    verify_certificate(tls_dir / "server.crt", tls_dir / "server.key", tls_dir / "ca.crt",
                       [announce_ip], "Redis/Sentinel")
    private_node_ip(configs["redis"].get("REDIS_EXTERNAL_IP", ""), "REDIS_EXTERNAL_IP")
    if not env.get("REDIS_COMPOSE_PROJECT"):
        raise SetupError("Set a unique REDIS_COMPOSE_PROJECT for this host.")
    compose_config("--env-file", "redis/.env", "-p", env["REDIS_COMPOSE_PROJECT"],
                   "-f", "redis/docker-compose.ha-node.yml", env=env)
    subprocess.run(["docker", "compose", "--env-file", "redis/.env", "-p", env["REDIS_COMPOSE_PROJECT"],
                    "-f", "redis/docker-compose.ha-node.yml", "up", "-d"], cwd=ROOT, env=env, check=True)
    subprocess.run([str(ROOT / "redis" / "init-redis-ha-node.sh")], cwd=ROOT, env=env, check=True)
    print("Redis node/Sentinel are running. Add the remaining hosts and verify firewall reachability before failover testing.")


def deploy_local(args: argparse.Namespace) -> None:
    validate(argparse.Namespace(profile="development", sql_host=None, es_host=None, redis_sentinels=None))
    subprocess.run([str(ROOT / "ops" / "migrate-local-redis-ha.sh")], cwd=ROOT, check=True)
    subprocess.run(
        ["docker", "compose", "-p", "project-agora-db", "-f", "docker-compose.yml", "up", "-d",
         "mssql", "elasticsearch"],
        cwd=ROOT, check=True,
    )
    containers = {
        "mssql": "agora-mssql",
        "elasticsearch": "agora-elasticsearch",
        "redis-primary": "agora-redis-primary",
        "redis-replica-1": "agora-redis-replica-1",
        "redis-replica-2": "agora-redis-replica-2",
        "redis-sentinel-1": "agora-redis-sentinel-1",
        "redis-sentinel-2": "agora-redis-sentinel-2",
        "redis-sentinel-3": "agora-redis-sentinel-3",
    }
    deadline = time.monotonic() + 600
    pending = set(containers)
    while pending and time.monotonic() < deadline:
        for service in list(pending):
            inspect = subprocess.run(["docker", "inspect", "--format", "{{.State.Health.Status}}", containers[service]],
                                     capture_output=True, text=True)
            if inspect.returncode == 0 and inspect.stdout.strip() == "healthy":
                pending.remove(service)
        if pending:
            time.sleep(3)
    if pending:
        raise SetupError("Services did not become healthy: " + ", ".join(sorted(pending)))
    for script in (
        "mssql/init-mssql.sh",
        "redis/init-redis-sentinel.sh",
        "elasticsearch/init-elasticsearch.sh",
    ):
        subprocess.run([str(ROOT / script)], cwd=ROOT, check=True)
    print("Local Sentinel HA development services are initialized. This mode is not a multi-host production deployment.")


def prepare_storage(args: argparse.Namespace) -> None:
    subprocess.run([str(ROOT / "elasticsearch" / "prepare-storage.sh")], cwd=ROOT, check=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    preparation = subparsers.add_parser("prepare", help="Create owner-only TLS env files and replace template secrets; never generate certificates.")
    preparation.add_argument("--tls-dir", type=Path, help="Manually supplied TLS bundle directory (see TLS_SETUP.md).")
    check = subparsers.add_parser("validate", help="Validate secrets, TLS, network addresses, and Compose syntax.")
    check.add_argument("--profile", choices=("development", "production"), default="development")
    check.add_argument("--sql-host", help="SQL listener name/IP used by applications and TLS SAN validation.")
    check.add_argument("--sql-node-hostname", help="Optional local SQL node name to verify against its certificate SAN.")
    check.add_argument("--es-host", help="Elasticsearch host used by applications and TLS SAN validation.")
    check.add_argument("--redis-sentinels", help="Three comma-separated private host:26379 seeds.")
    check.add_argument("--backup-root", help="Existing durable-storage mount containing ES_SNAPSHOT_HOST_DIR.")
    production = subparsers.add_parser("configure-production", help="Write production TLS, address, and snapshot settings after validating certificates and storage.")
    production.add_argument("--sql-host", required=True, help="Private SQL AG listener name/IP; must be covered by the SQL certificate SAN.")
    production.add_argument("--sql-node-hostname", required=True, help="This host's SQL Server hostname covered by its node certificate.")
    production.add_argument("--sql-bind-ip", required=True, help="This SQL host's private IPv4 interface address.")
    production.add_argument("--sql-port", type=int, default=1433, help="SQL listener port used by host-side maintenance tools.")
    production.add_argument("--es-host", required=True, help="Private Elasticsearch endpoint covered by its certificate SAN.")
    production.add_argument("--es-bind-ip", required=True, help="Private IPv4 on which Elasticsearch publishes port 9200.")
    production.add_argument("--redis-primary-ip", required=True, help="Private IP of the initial Redis primary.")
    production.add_argument("--redis-sentinels", required=True, help="Three comma-separated private host:26379 seeds.")
    production.add_argument("--sql-cert-dir", required=True, help="Absolute directory containing server.crt, server.key, and ca.crt.")
    production.add_argument("--es-cert-dir", required=True, help="Absolute directory containing http.crt, http.key, and ca.crt.")
    production.add_argument("--redis-cert-dir", required=True, help="Absolute directory containing Redis server.crt, server.key, and ca.crt.")
    production.add_argument("--backup-root", required=True, help="Existing mounted durable-storage root.")
    production.add_argument("--es-snapshot-dir", help="Optional absolute directory inside --backup-root.")
    sync = subparsers.add_parser("sync-backend", help="Copy DB connection settings into an existing BE .env without changing unrelated keys.")
    sync.add_argument("--backend-env", default=str(ROOT.parent / "project-agora-BE" / ".env"))
    sync.add_argument("--db-host", required=True)
    sync.add_argument("--db-port", type=int, default=1433)
    sync.add_argument("--multi-subnet", action="store_true")
    sync.add_argument("--db-freetds-conf", required=True, help="Absolute strict-TLS FreeTDS config path available to C++.")
    sync.add_argument("--es-host", required=True)
    sync.add_argument("--es-port", type=int, default=9200)
    sync.add_argument("--es-ca-cert", required=True, help="Absolute CA path available inside the BE runtime.")
    sync.add_argument("--redis-ca-cert", required=True, help="Absolute Redis CA path available inside the BE runtime.")
    sync.add_argument("--redis-sentinels", required=True, help="Three comma-separated private host:26379 seeds.")
    subparsers.add_parser("prepare-storage", help="Prepare Elasticsearch snapshot/certificate directories and UID access.")
    subparsers.add_parser("deploy-local", help="Start and initialize the development Sentinel HA stack.")
    subparsers.add_parser("deploy-sql-ag-node", help="Start one configured SQL Server AG container; does not create the AG.")
    subparsers.add_parser("deploy-redis-ha-node", help="Start and initialize one Redis/Sentinel HA host.")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "prepare":
            prepare(args.tls_dir)
        elif args.command == "validate":
            validate(args)
        elif args.command == "configure-production":
            configure_production(args)
        elif args.command == "sync-backend":
            sync_backend(args)
        elif args.command == "prepare-storage":
            prepare_storage(args)
        elif args.command == "deploy-local":
            deploy_local(args)
        elif args.command == "deploy-sql-ag-node":
            deploy_sql_node(args)
        elif args.command == "deploy-redis-ha-node":
            deploy_redis_node(args)
        return 0
    except (SetupError, OSError, subprocess.CalledProcessError) as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
