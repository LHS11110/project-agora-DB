# Redis Sentinel HA migration

Both HA Compose paths keep Redis Stack, RedisJSON, RediSearch, the `canvas:*`
key namespace, and the current JSON document structure. They use one primary,
two replicas, and three Sentinels. This is replication and automatic failover,
not data sharding.

Redis OSS Cluster sharding is not used because Redis documents Search as
unavailable with the OSS Cluster API. Sentinel clients must explicitly support
Sentinel to discover the promoted primary ([Redis Search limitations](https://redis.io/docs/latest/operate/oss_and_stack/stack-with-enterprise/search/),
[Sentinel client requirements](https://redis.io/docs/latest/develop/reference/sentinel-clients/)).

## Move the current single-node data

The HA Compose project creates new named volumes, so it will not see the
existing `redis_data` volume automatically. Save an RDB snapshot while the
single-node Redis is still running:

```bash
./redis/snapshot-standalone.sh
```

The snapshot is written to `/tmp/agora-redis-dump.rdb` with mode `0600`; treat
it as application data. Stop the standalone Redis and create the new primary
container. Import through a short-lived helper container that mounts the
actual named volume; copying to a stopped container does not reliably write
through its volume mount:

```bash
docker compose --env-file redis/.env -p project-agora-db -f redis/docker-compose.yml stop redis-stack
docker compose --env-file redis/.env -p agora-redis-ha \
  -f redis/docker-compose.sentinel.yml create redis-primary
./redis/import-rdb-into-ha-volume.sh /tmp/agora-redis-dump.rdb agora-redis-primary
REDIS_NODE_APPENDONLY=no docker compose --env-file redis/.env -p agora-redis-ha \
  -f redis/docker-compose.sentinel.yml up -d redis-primary
# Confirm the expected key count and RediSearch index before proceeding.
docker compose --env-file redis/.env -p agora-redis-ha \
  -f redis/docker-compose.sentinel.yml stop redis-primary
REDIS_NODE_APPENDONLY=yes docker compose --env-file redis/.env -p agora-redis-ha \
  -f redis/docker-compose.sentinel.yml up -d redis-primary
REDIS_NODE_APPENDONLY=yes docker compose --env-file redis/.env -p agora-redis-ha \
  -f redis/docker-compose.sentinel.yml up -d redis-primary redis-replica-1 \
  redis-replica-2 redis-sentinel-1 redis-sentinel-2 redis-sentinel-3
./redis/init-redis-sentinel.sh
```

The replicas synchronize from that primary. Keep the old standalone volume
and the snapshot until the new data and search index have been checked.

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
permit failover or configuration changes. Do not deploy with the
unauthenticated development fallback. Keep port 26379 firewalled to the
application and Redis hosts.

Set `REDIS_EXTERNAL_IP` in `redis/.env` to the initial primary's client-facing
address before running the primary initializer. SQL stores that endpoint for
the existing `redis_id` registration, while BE/C++ in Sentinel mode use the
configured Sentinel seeds to discover the current primary and ignore the row's
IP/port for data connections. Failover does not require changing the row.

`REDIS_NODE_ANNOUNCE_IP` must be reachable from every Redis node and client.
Allow Redis port 6379 between nodes and clients, and Sentinel port 26379
between nodes and Sentinel clients. Restrict both ports to trusted private
networks. This file uses host networking so Sentinel can advertise those node
addresses without Docker port translation. Redis TLS is not enabled in these
Compose files; use a trusted private network or add TLS together with matching
client configuration before production deployment.

## Local failover lab and data safety

`redis/docker-compose.sentinel.yml` runs all six Redis/Sentinel containers on
one host for development and failover exercises. It does not protect against
that host failing. Redis uses asynchronous replication, so failover can lose
the most recent writes if they had not reached a replica yet.

The repository's maintenance CLI scripts locate the current primary by
checking the local Redis/Sentinel containers. The existing `redis_server`
table continues to register the initial primary endpoint for the logical Redis
service. BE/C++ use `REDIS_SENTINELS` and `REDIS_SENTINEL_MASTER_NAME` to
discover the current primary, so they keep the same `redis_id` across failover.

Run the local automatic failover exercise after starting and initializing the
Sentinel lab:

```bash
docker compose stop redis-stack
docker compose --env-file redis/.env -f redis/docker-compose.sentinel.yml up -d
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
