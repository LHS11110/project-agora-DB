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
it as application data. Then stop the standalone Redis, create the new
primary container and copy the snapshot into its `/data` volume before it
starts:

```bash
docker compose stop redis-stack
docker compose --env-file redis/.env -f redis/docker-compose.sentinel.yml create redis-primary
docker cp /tmp/agora-redis-dump.rdb agora-redis-primary:/data/dump.rdb
docker compose --env-file redis/.env -f redis/docker-compose.sentinel.yml up -d
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
docker cp /tmp/agora-redis-dump.rdb agora-redis-node:/data/dump.rdb
REDIS_NODE_HOSTNAME=agora-r1 \
REDIS_NODE_ANNOUNCE_IP=10.0.0.21 \
REDIS_SENTINEL_MASTER_HOST=10.0.0.21 \
docker compose --env-file redis/.env -p agora-redis-a \
  -f redis/docker-compose.ha-node.yml up -d
./redis/init-redis-ha-node.sh
```

On the two replica hosts, set `REDIS_NODE_PRIMARY_HOST=10.0.0.21` and each
host's own unique `REDIS_NODE_HOSTNAME` and `REDIS_NODE_ANNOUNCE_IP`. Keep
`REDIS_SENTINEL_MASTER_HOST` set to the initial primary's reachable address on
all three hosts. Run `./redis/init-redis-ha-node.sh` on each host; it creates
the RediSearch index and registers the endpoint only on the primary.

Set `REDIS_EXTERNAL_IP` in `redis/.env` to the initial primary's client-facing
address before running the primary initializer. The current SQL registration
stores that one endpoint; after a failover, the application still needs
Sentinel discovery or a stable proxy.

`REDIS_NODE_ANNOUNCE_IP` must be reachable from every Redis node and client.
Allow Redis port 6379 between nodes and clients, and Sentinel port 26379
between nodes and Sentinel clients. Restrict both ports to trusted private
networks. This file uses host networking so Sentinel can advertise those node
addresses without Docker port translation.

## Local failover lab and data safety

`redis/docker-compose.sentinel.yml` runs all six Redis/Sentinel containers on
one host for development and failover exercises. It does not protect against
that host failing. Redis uses asynchronous replication, so failover can lose
the most recent writes if they had not reached a replica yet.

The repository's maintenance CLI scripts locate the current primary by
checking the local Redis/Sentinel containers. The existing `redis_server`
table continues to register the initial primary endpoint; an application that
must survive failover needs a Sentinel-aware client or a stable proxy endpoint.
