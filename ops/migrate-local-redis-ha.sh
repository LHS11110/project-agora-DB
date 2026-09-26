#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WAIT_SECONDS="${STACK_START_WAIT_SECONDS:-240}"
LEGACY_PROJECT="project-agora-db-ha"
CURRENT_PROJECT="project-agora-db"
COMPOSE_FILE="$ROOT/docker-compose.yml"
REDIS_ENV="$ROOT/redis/.env"
MIGRATION_MARKER="$ROOT/.redis-ha-migration-in-progress"

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[[ "$WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "STACK_START_WAIT_SECONDS must be a positive integer."
for file in "$REDIS_ENV" "$ROOT/mssql/.env" "$ROOT/elasticsearch/.env" "$COMPOSE_FILE"; do
    [[ -f "$file" && ! -L "$file" ]] || die "Required DB file is missing or unsafe: $file"
done
command -v docker >/dev/null 2>&1 || die "Docker is not installed or not on PATH."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."

legacy_volumes=(
    project-agora-db-ha_redis_primary_data
    project-agora-db-ha_redis_replica_1_data
    project-agora-db-ha_redis_replica_2_data
    project-agora-db-ha_redis_sentinel_1_data
    project-agora-db-ha_redis_sentinel_2_data
    project-agora-db-ha_redis_sentinel_3_data
    project-agora-db-ha_redis_insight_data
)
current_volumes=(
    project-agora-db_redis_primary_data
    project-agora-db_redis_replica_1_data
    project-agora-db_redis_replica_2_data
    project-agora-db_redis_sentinel_1_data
    project-agora-db_redis_sentinel_2_data
    project-agora-db_redis_sentinel_3_data
    project-agora-db_redis_insight_data
)
ha_containers=(
    agora-redis-primary agora-redis-replica-1 agora-redis-replica-2
    agora-redis-sentinel-1 agora-redis-sentinel-2 agora-redis-sentinel-3
)

volume_count() {
    local count=0 volume
    for volume in "$@"; do
        if docker volume inspect "$volume" >/dev/null 2>&1; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

assert_compose_project() {
    local name="$1" expected="$2" actual
    docker inspect "$name" >/dev/null 2>&1 || return 0
    actual="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
    [[ "$actual" == "$expected" ]] \
        || die "Container '$name' belongs to '${actual:-a non-Compose project}', expected '$expected'. Nothing was removed."
}

legacy_count="$(volume_count "${legacy_volumes[@]}")"
current_count="$(volume_count "${current_volumes[@]}")"
resume_migration=false
[[ -e "$MIGRATION_MARKER" ]] && resume_migration=true
(( legacy_count == 0 || legacy_count == ${#legacy_volumes[@]} )) \
    || die "Only some legacy Sentinel volumes exist ($legacy_count/${#legacy_volumes[@]}). Restore or inspect them before switching Compose projects."
if (( legacy_count > 0 && current_count > 0 && current_count < ${#current_volumes[@]} )) \
    && [[ "$resume_migration" != true ]]; then
    die "Only some current Sentinel volumes exist ($current_count/${#current_volumes[@]}). Refusing a partial data migration."
fi
if [[ "$resume_migration" == true ]] && (( legacy_count != ${#legacy_volumes[@]} )); then
    die "An interrupted Redis migration marker exists but the complete source volumes are missing. Inspect the deployment before retrying."
fi

# Preserve the old named standalone data volume. Import its RDB into the HA
# primary before explicitly allowing this one-time Compose project transition.
if docker volume inspect project-agora-db_redis_data >/dev/null 2>&1 \
    && [[ "${ALLOW_STANDALONE_DATA_RETAINED:-false}" != true ]]; then
    die "The standalone Redis data volume exists. Import it using redis/cluster/README.md before switching to Sentinel HA; the volume will be preserved."
fi

assert_compose_project agora-redis-stack "$CURRENT_PROJECT"
for name in "${ha_containers[@]}"; do
    if docker inspect "$name" >/dev/null 2>&1; then
        owner="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
        [[ "$owner" == "$LEGACY_PROJECT" || "$owner" == "$CURRENT_PROJECT" ]] \
            || die "Container '$name' belongs to '${owner:-a non-Compose project}'. Nothing was removed."
    fi
done

legacy_container_count=0
current_container_count=0
for name in "${ha_containers[@]}"; do
    if docker inspect "$name" >/dev/null 2>&1; then
        owner="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
        [[ "$owner" == "$LEGACY_PROJECT" ]] && legacy_container_count=$((legacy_container_count + 1))
        [[ "$owner" == "$CURRENT_PROJECT" ]] && current_container_count=$((current_container_count + 1))
    fi
done
(( legacy_container_count == 0 || current_container_count == 0 )) \
    || die "Redis HA containers are split across the old and current Compose projects. Resolve the mixed deployment before retrying."

if docker inspect agora-redis-stack >/dev/null 2>&1; then
    printf 'Stopping and removing the retired standalone Redis container; its volumes are retained...\n'
    if [[ "$(docker inspect --format '{{.State.Running}}' agora-redis-stack 2>/dev/null || true)" == true ]]; then
        docker stop agora-redis-stack >/dev/null
    fi
    docker rm agora-redis-stack >/dev/null
fi

if (( legacy_container_count > 0 )); then
    printf 'Stopping the old Sentinel Compose project without deleting its volumes...\n'
    docker compose --env-file "$REDIS_ENV" -p "$LEGACY_PROJECT" \
        -f "$ROOT/redis/docker-compose.sentinel.yml" down
fi

if docker network inspect agora-redis-ha >/dev/null 2>&1; then
    network_project="$(docker network inspect --format '{{ index .Labels "com.docker.compose.project" }}' agora-redis-ha 2>/dev/null || true)"
    if [[ "$network_project" != "$CURRENT_PROJECT" ]]; then
        endpoints="$(docker network inspect --format '{{range .Containers}}{{.Name}} {{end}}' agora-redis-ha 2>/dev/null || true)"
        [[ -z "$endpoints" ]] || die "Legacy network agora-redis-ha is still attached to: $endpoints. Detach those containers before retrying."
        docker network rm agora-redis-ha >/dev/null
    fi
fi

if (( legacy_count > 0 )) && { (( current_count == 0 )) || [[ "$resume_migration" == true ]]; }; then
    printf 'Creating current-project Redis volumes and copying the stopped Sentinel data...\n'
    if [[ "$resume_migration" == true ]]; then
        docker compose --env-file "$REDIS_ENV" -p "$CURRENT_PROJECT" -f "$COMPOSE_FILE" stop \
            redis-primary redis-replica-1 redis-replica-2 \
            redis-sentinel-1 redis-sentinel-2 redis-sentinel-3 redis-insight || true
    fi
    : > "$MIGRATION_MARKER"
    docker compose --env-file "$REDIS_ENV" -p "$CURRENT_PROJECT" -f "$COMPOSE_FILE" create \
        redis-primary redis-replica-1 redis-replica-2 \
        redis-sentinel-1 redis-sentinel-2 redis-sentinel-3 redis-insight
    for index in "${!legacy_volumes[@]}"; do
        docker volume inspect "${current_volumes[$index]}" >/dev/null 2>&1 \
            || die "Compose did not create expected volume '${current_volumes[$index]}'."
        docker run --rm --network none \
            --volume "${legacy_volumes[$index]}:/from:ro" \
            --volume "${current_volumes[$index]}:/to" \
            redis:8.6.7 sh -c 'cp -a /from/. /to/'
    done
fi

printf 'Starting the default Redis Sentinel HA services and waiting for health...\n'
docker compose --env-file "$REDIS_ENV" -p "$CURRENT_PROJECT" -f "$COMPOSE_FILE" \
    up -d --wait --wait-timeout "$WAIT_SECONDS" \
    redis-primary redis-replica-1 redis-replica-2 \
    redis-sentinel-1 redis-sentinel-2 redis-sentinel-3 redis-insight

rm -f "$MIGRATION_MARKER"
printf 'Redis Sentinel HA is running under Compose project %s.\n' "$CURRENT_PROJECT"
