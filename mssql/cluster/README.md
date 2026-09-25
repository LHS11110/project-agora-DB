# SQL Server Availability Group deployment

The existing `mssql/docker-compose.yml` remains the single-node development
stack. For a cluster, run `docker-compose.node.yml` once on each SQL Server
Linux host and manage the Availability Group with Pacemaker on the hosts.

## Topology and compatibility

- Keep SQL Server 2022 and the existing `agora_db` schema.
- Use SQL Server Standard for the two data replicas in a Basic Availability
  Group. It supports one database and two replicas, which matches this
  repository's single application database. Add a third configuration-only
  replica for automatic failover; that SQL Server instance can use Express.
- Configure an `EXTERNAL` Availability Group and a Pacemaker listener/VIP.
  Point the existing BE `DB_HOST` value at that listener name. For SQL
  maintenance scripts, set `MSSQL_EXTERNAL_IP`/`MSSQL_EXTERNAL_PORT` in
  `mssql/.env` to the listener and run them from a host with `sqlcmd`
  installed. `DB_NAME`, tables, and T-SQL remain unchanged.
- Run the SQL Server nodes on separate Linux hosts or VMs. Do not use the
  single-host Compose lab as production HA: production Pacemaker deployments
  need quorum and a platform-appropriate fencing agent (STONITH).
- The per-node Compose file only starts SQL Server; it does not provision or
  manage Pacemaker. Microsoft documents container HA with Kubernetes,
  OpenShift, or DH2i. For production, use one of those supported container
  patterns or install SQL Server directly on supported Linux hosts with
  Pacemaker rather than treating this Compose file as the HA manager.

## Per-node Compose setup

On each of three SQL Server hosts, provide the same `mssql/.env` secrets and
set unique node values in the shell before starting the service. Use
`MSSQL_NODE_PID=Standard` on the two data replicas and
`MSSQL_NODE_PID=Express` on the configuration-only replica:

```bash
MSSQL_NODE_HOSTNAME=agora-sql-a \
MSSQL_NODE_BIND_IP=10.0.0.11 \
MSSQL_NODE_PID=Standard \
MSSQL_NODE_PORT=1433 \
MSSQL_AG_ENDPOINT_PORT=5022 \
docker compose --env-file mssql/.env -p agora-mssql-node-a \
  -f mssql/cluster/docker-compose.node.yml up -d
```

`MSSQL_NODE_HOSTNAME` must be unique and 15 characters or fewer. The
Pacemaker resource agent's node name must match SQL Server's `ServerName`
property. Use the host's private IP for `MSSQL_NODE_BIND_IP`. On the other
hosts, use each host's own private IP, a distinct hostname, and a distinct
Compose project name. Make each node hostname resolve to its private IP from
every SQL host. Permit SQL
traffic on 1433 and the database mirroring endpoint on 5022 between the nodes;
configure Pacemaker/Corosync ports and fencing through the host operating system.

## Bootstrap order

1. Install and configure Pacemaker, Corosync, and a fencing agent on all three
   hosts. Confirm quorum and fencing before creating production resources.
2. Start two SQL Server Standard data nodes and one SQL Server Express
   configuration-only node with the Compose file above. Set
   `MSSQL_EXTERNAL_IP` to the intended primary node while bootstrapping; after
   the listener is online, change it to the listener address for maintenance
   scripts.
3. For a new deployment, initialize `agora_db` and its schema on the intended
   primary. To migrate existing data, back up the current `agora_db` and
   restore it to the new primary; the Compose volume is new and does not
   contain the current database. Run `./mssql/init-mssql.sh` against that
   restored database to establish the application login and verify/update the
   existing schema without replacing its rows. During cutover, pause writes
   for the final backup and point `MSSQL_EXTERNAL_IP`/`MSSQL_EXTERNAL_PORT` at
   the current primary until the listener is ready.
4. Set the database to FULL recovery and take a full backup if it is not
   already in that state. Create matching server logins on the secondary data
   replica with the primary login's SID. Availability Groups replicate the
   database and its database users, but not instance-level logins.
5. Back up and restore `agora_db` to the secondary with `NORECOVERY`; create a
   two-data-replica, synchronous Basic Availability Group with
   `CLUSTER_TYPE = EXTERNAL`, add the third instance as a configuration-only
   replica, and create database mirroring endpoints on port 5022.
6. Create the Pacemaker login and grant its required permissions on all AG
   instances. Store the credentials in the host resource-agent secret file.
7. Add the AG as a Pacemaker resource and associate its listener IP resource
   with the promoted AG resource. Register a DNS name for that listener.
8. Point clients and maintenance scripts at the listener, then verify a
   planned failover and a host failure before production use.

See Microsoft's current [Linux AG high availability guide](https://learn.microsoft.com/en-us/sql/linux/high-availability/availability-groups-configure?view=sql-server-ver17)
and [Pacemaker AG resource guide](https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-availability-group-cluster-pacemaker?view=sql-server-ver17)
for the host-specific Pacemaker commands. See the [SQL Server container HA
overview](https://learn.microsoft.com/en-us/sql/linux/business-continuity/containers/high-availability-overview?view=sql-server-ver17)
for supported container patterns. Fencing and listener IP values depend on
the target network and are intentionally not guessed here.

## Planned failover exercise

Run this on an AG Pacemaker node after confirming that the target data replica
is online and synchronous. For `CLUSTER_TYPE = EXTERNAL`, use Pacemaker for the
planned move; don't issue `ALTER AVAILABILITY GROUP ... FAILOVER` directly.

```bash
sudo pcs status --full
sudo pcs resource move <AG-resource>-master <target-pacemaker-node> --master --lifetime=30S

# Connect through the listener and confirm that it routes to the new primary.
sqlcmd -S tcp:<AG-listener>,<port> -d agora_db -U <application-user> -C \
  -Q "SELECT @@SERVERNAME AS primary_instance, sys.fn_hadr_is_primary_replica(N'agora_db') AS is_primary;"

sudo pcs resource clear <AG-resource>-master
sudo pcs status --full
```

Use the promotable resource name and node name shown by `pcs status` for the
actual cluster. Confirm `is_primary = 1`, the listener is online on the new
primary, and an application write through the listener succeeds after the
existing connection is discarded and recreated. The `--lifetime=30S` option
limits the temporary move constraint; clear the resource after checking the
transition. This planned test doesn't simulate node fencing or a host failure.
For the required external-cluster failover procedure, see Microsoft's
[AG failover guide](https://learn.microsoft.com/en-us/sql/linux/business-continuity/availability-groups/failover-high-availability?view=sql-server-ver17).

To exercise automatic host-failure handling, use an isolated staging cluster
with working quorum and fencing. Record the current primary, then power off
that SQL host or VM through the infrastructure control plane. Confirm that
Pacemaker fences the failed node, promotes the synchronous data replica, and
moves the listener; verify `is_primary = 1` through the listener and send a
write through the application. Restore the failed host and wait for the
replica to synchronize before ending the exercise. This scenario tests host
failure and fencing; a planned `pcs resource move` does not.
