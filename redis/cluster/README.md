# Redis Sentinel HA migration

Both HA Compose paths keep Redis Stack, RedisJSON, RediSearch, the `canvas:*`
key namespace, and the current JSON document structure. They use one primary,
two replicas, and three Sentinels. This is replication and automatic failover,
not data sharding.

Redis OSS Cluster sharding is not used because Redis documents Search as
unavailable with the OSS Cluster API. Sentinel clients must explicitly support
Sentinel to discover the promoted primary ([Redis Search limitations](https://redis.io/docs/latest/operate/oss_and_stack/stack-with-enterprise/search/),
[Sentinel client requirements](https://redis.io/docs/latest/develop/reference/sentinel-clients/)).

## Move legacy single-node data into HA

The standalone Compose service has been removed. For a host that still has the
old `agora-redis-stack` container and `project-agora-db_redis_data` volume,
export one RDB while that container is still running:

```bash
./redis/export-legacy-redis-rdb.sh /tmp/agora-redis-dump.rdb
```

The RDB is written with mode `0600`; treat it as application data. The export
helper only reads the retired container and is not a way to deploy standalone
Redis. Stop and remove that container while retaining its volume, then create
the new HA primary. The import helper mounts the actual named volume; copying
to a stopped container does not reliably write through its volume mount:

```bash
docker stop agora-redis-stack
docker rm agora-redis-stack
docker compose create redis-primary
./redis/import-rdb-into-ha-volume.sh /tmp/agora-redis-dump.rdb agora-redis-primary
REDIS_NODE_APPENDONLY=no docker compose up -d redis-primary
# Confirm the expected key count and RediSearch index before proceeding.
docker compose stop redis-primary
REDIS_NODE_APPENDONLY=yes ALLOW_STANDALONE_DATA_RETAINED=true ./ops/migrate-local-redis-ha.sh
./redis/init-redis-sentinel.sh
```

The migration command starts all six Sentinel HA containers. The replicas
synchronize from the restored primary. The old volume is intentionally
retained; remove it manually only after the HA data and search index are
verified and a separate backup exists.

## Multi-host deployment

Use `redis/docker-compose.ha-node.yml` once on each of three hosts. Copy the
same `redis/.env` secrets to each host and set the per-host hostname/IP values
when running Compose. The initial primary host example is:

```bash
REDIS_NODE_HOSTNAME=agora-r1 \
REDIS_NODE_ANNOUNCE_IP=10.0.0.21 \
REDIS_SENTINEL_MASTER_HOST=10.0.0.21 \
docker compose --env-file redis/.env -p agora-redis-a \
  -f redis/docker-compose.ha-node.yml create redis-node
./redis/import-rdb-into-ha-volume.sh /tmp/agora-redis-dump.rdb agora-redis-node
REDIS_NODE_HOSTNAME=agora-r1 \
REDIS_NODE_ANNOUNCE_IP=10.0.0.21 \
REDIS_SENTINEL_MASTER_HOST=10.0.0.21 \
REDIS_NODE_APPENDONLY=no \
docker compose --env-file redis/.env -p agora-redis-a \
  -f redis/docker-compose.ha-node.yml up -d redis-node
# Verify the restored key count and search index, then stop and restart the
# node with REDIS_NODE_APPENDONLY=yes before starting the Sentinel service.
docker compose --env-file redis/.env -p agora-redis-a \
  -f redis/docker-compose.ha-node.yml stop redis-node
REDIS_NODE_HOSTNAME=agora-r1 \
REDIS_NODE_ANNOUNCE_IP=10.0.0.21 \
REDIS_SENTINEL_MASTER_HOST=10.0.0.21 \
REDIS_NODE_APPENDONLY=yes \
docker compose --env-file redis/.env -p agora-redis-a \
  -f redis/docker-compose.ha-node.yml up -d redis-node redis-sentinel
./redis/init-redis-ha-node.sh
```

On the two replica hosts, set `REDIS_NODE_PRIMARY_HOST=10.0.0.21` and each
host's own unique `REDIS_NODE_HOSTNAME` and `REDIS_NODE_ANNOUNCE_IP`. Keep
`REDIS_SENTINEL_MASTER_HOST` set to the initial primary's reachable address on
all three hosts. Run `./redis/init-redis-ha-node.sh` on each host; it creates
the RediSearch index and registers the endpoint only on the primary.

The Redis node and Sentinel bind to `REDIS_NODE_ANNOUNCE_IP` by default, so
host-network services listen on that interface rather than every host
interface. Set `REDIS_NODE_BIND_IP` or `REDIS_SENTINEL_BIND_IP` only when the
listen address differs from the announced private address. The Sentinel peer
ACL uses the existing Redis admin password. Set a separate
`REDIS_SENTINEL_USER` and `REDIS_SENTINEL_PASSWORD` in `redis/.env` and in the
BE secret environment. The generated reader ACL permits read-only topology
queries needed by Sentinel clients, including `SENTINEL MASTERS`; it does not
permit failover or configuration changes. Sentinel credentials are mandatory
for all application and maintenance clients. Keep port 26379 firewalled to the
application and Redis hosts.

Set `REDIS_EXTERNAL_IP` in `redis/.env` to the initial primary's private,
client-reachable address before running the primary initializer. SQL keeps
one active `redis_server` row for the HA service and preserves older rows as
inactive records so existing foreign keys remain valid. BE/C++ require the
configured Sentinel seeds to discover the current primary and ignore the
row's IP/port for Redis data connections. Failover does not require changing
the row.

`REDIS_NODE_ANNOUNCE_IP` must be reachable from every Redis node and client.
Allow Redis port 6379 between nodes and clients, and Sentinel port 26379
between nodes and Sentinel clients. Restrict both ports to trusted private
networks. This file uses host networking so Sentinel can advertise those node
addresses without Docker port translation. Set `REDIS_TLS_ENABLED=true` and
provide each host's `server.crt`, `server.key`, and trusted `ca.crt` through
`REDIS_TLS_CERTS_DIR`. Redis, replication links, Sentinel peer links, and BE
clients then use TLS, with the plaintext listener disabled. Certificates must
cover each advertised Redis and Sentinel address in their SANs, and BE/C++
must trust the issuing CA. Confirm private routing and firewall rules from
every app/replica host before deployment; a private IP by itself does not prove
that packets avoid untrusted network paths.

## Local failover lab and data safety

The root Compose includes `redis/docker-compose.sentinel.yml` and runs the six
Redis/Sentinel containers on one host in an `internal: true` Docker network
for development and failover exercises. Redis ports are TLS-only; host
applications use the configured Docker bridge addresses in
`REDIS_SENTINELS`. This setup does not protect against that host failing.
Redis uses asynchronous replication, so failover can lose the most recent
writes if they had not reached a replica yet.

### Restart the local Sentinel lab

Run these commands from the repository root. If upgrading from the previous
`project-agora-db-ha` project, first run `./ops/migrate-local-redis-ha.sh` to
copy the existing HA volumes into the default project. The old volumes remain
as a rollback copy. `up -d` starts the primary first, then its replicas and
Sentinels, and also starts Redis Insight.

```bash
docker compose up -d redis-primary redis-replica-1 redis-replica-2 \
  redis-sentinel-1 redis-sentinel-2 redis-sentinel-3 redis-insight
docker compose ps
```

Wait for the primary, both replicas, and all three Sentinels to show `healthy`;
Redis Insight should show `running`. `docker compose up` starts Redis services
but does not create the app ACL, search index, or SQL registration. Run
`./redis/init-redis-sentinel.sh` after SQL schema initialization and whenever
the HA Redis registration needs repair. To stop this stack while retaining
data, run the following command. Do not use `down -v` when you need to keep
the Redis data.

```bash
docker compose stop redis-primary redis-replica-1 redis-replica-2 \
  redis-sentinel-1 redis-sentinel-2 redis-sentinel-3 redis-insight
```

The repository's maintenance CLI scripts locate the current primary by
checking the local Redis/Sentinel containers. The existing `redis_server`
table continues to register the initial primary endpoint for the logical Redis
service. BE/C++ use `REDIS_SENTINELS` and `REDIS_SENTINEL_MASTER_NAME` to
discover the current primary, so they keep the same `redis_id` across failover.

Run the local automatic failover exercise after starting and initializing the
Sentinel lab:

```bash
docker compose up -d redis-primary redis-replica-1 redis-replica-2 \
  redis-sentinel-1 redis-sentinel-2 redis-sentinel-3 redis-insight
./redis/init-redis-sentinel.sh
./redis/test-failover.sh
```

The script uses only the six local lab containers. It authenticates Sentinel
queries with `REDIS_SENTINEL_USER`/`REDIS_SENTINEL_PASSWORD` when configured.
It waits for the probe document to reach both replicas, stops the current
primary, checks that all three Sentinels report the promoted node, verifies
RedisJSON and RediSearch on it, restarts the old primary, and waits for all
three nodes to return to a primary/replica topology. It deletes its temporary
probe key after success.
The test introduces a brief Redis interruption; don't run it against a live
service.

### Restart a multi-host Redis/Sentinel node

On each host, reuse the same Compose project name and host-specific settings
used when that node was first deployed. This preserves that host's Redis and
Sentinel named volumes. For example, on the initial primary host:

```bash
export REDIS_COMPOSE_PROJECT=agora-redis-a
export REDIS_NODE_HOSTNAME=agora-r1
export REDIS_NODE_ANNOUNCE_IP=10.0.0.21
export REDIS_NODE_BIND_IP=10.0.0.21
export REDIS_SENTINEL_BIND_IP=10.0.0.21
export REDIS_SENTINEL_MASTER_HOST=10.0.0.21

docker compose --env-file redis/.env -p "$REDIS_COMPOSE_PROJECT" \
  -f redis/docker-compose.ha-node.yml up -d redis-node redis-sentinel
docker compose --env-file redis/.env -p "$REDIS_COMPOSE_PROJECT" \
  -f redis/docker-compose.ha-node.yml ps
```

For a replica, also export its original `REDIS_NODE_PRIMARY_HOST` and retain
its original project name, hostname, announce/bind IPs, TLS certificate path,
and ports. Repeat on each node host. Wait for the node and Sentinel health
checks, then confirm from the cluster that the replica has synchronized and
all Sentinels see the same primary. A routine restart does not require
`init-redis-ha-node.sh` or data import. Coordinate a production node restart
with the service owner so the application and firewall paths remain available.
