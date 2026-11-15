#!/usr/bin/env python3
"""SQL Server regression: IRADE workspaces use dedicated tables isolated from canvas_info."""
import argparse
from pathlib import Path
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', default='agora-mssql')
    args = parser.parse_args()
    migrations = Path(__file__).resolve().parents[1] / 'migrations'
    name = 'irade_workspace_schema_' + uuid.uuid4().hex[:12]
    command = [
        'docker', 'exec', '-i', args.container, '/bin/bash', '-lc',
        'export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"; exec /opt/mssql-tools18/bin/sqlcmd "$@"',
        'sqlcmd', '-S', 'localhost', '-U', 'sa', '-C', '-b', '-I',
    ]

    def sql(text, database='master'):
        result = subprocess.run(command + ['-d', database], input=text, text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError((result.stdout + result.stderr)[-2000:])
        return result.stdout

    migration_sql = (migrations / '2026-11-13-irade-workspace.sql').read_text()
    created = False
    try:
        sql(f"IF DB_ID(N'{name}') IS NOT NULL THROW 51000,'Test database exists',1; CREATE DATABASE [{name}];\nGO\n")
        created = True
        sql("""
CREATE TABLE dbo.redis_server (
    redis_id INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    redis_ip VARCHAR(64) NOT NULL,
    redis_port INT NOT NULL
);
CREATE TABLE dbo.cpp_server (
    server_id INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    server_ip VARCHAR(64) NOT NULL,
    server_port INT NOT NULL
);
CREATE TABLE dbo.canvas_info (
    canvas_id INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    redis_id INT NULL REFERENCES dbo.redis_server(redis_id),
    cpp_server_id INT NULL REFERENCES dbo.cpp_server(server_id),
    is_cached BIT NOT NULL DEFAULT 0,
    created_at DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
CREATE ROLE [agora_runtime];
GO
""", name)
        # Idempotent migration execution.
        sql(migration_sql, name)
        sql(migration_sql, name)

        # Verify workspace_info identity starts independently and FK constraints hold.
        sql("""
INSERT INTO dbo.redis_server (redis_ip, redis_port) VALUES ('127.0.0.1', 6379);
INSERT INTO dbo.cpp_server (server_ip, server_port) VALUES ('127.0.0.1', 8080);
INSERT INTO dbo.canvas_info (redis_id, cpp_server_id, is_cached) VALUES (1, 1, 1);
INSERT INTO dbo.workspace_info (redis_id, cpp_server_id, is_cached) VALUES (1, 1, 1);
INSERT INTO dbo.workspace_runtime_cleanup (workspace_id) VALUES (1);
IF (SELECT COUNT(*) FROM dbo.workspace_info WHERE workspace_id = 1) <> 1 THROW 51000, 'Expected workspace #1', 1;
IF (SELECT COUNT(*) FROM dbo.canvas_info WHERE canvas_id = 1) <> 1 THROW 51000, 'Expected canvas #1', 1;
DELETE FROM dbo.workspace_info WHERE workspace_id = 1;
IF (SELECT COUNT(*) FROM dbo.canvas_info WHERE canvas_id = 1) <> 1 THROW 51000, 'Canvas #1 affected by workspace delete', 1;
GO
""", name)
        fk_reject = subprocess.run(
            command + ['-d', name],
            input="INSERT INTO dbo.workspace_info (redis_id) VALUES (99999);\nGO\n",
            text=True,
            capture_output=True,
        )
        if fk_reject.returncode == 0:
            raise RuntimeError('Expected FK rejection for missing redis_id')
        print('PASS SQL Server: workspace_info & workspace_runtime_cleanup isolated from canvas_info and idempotent')
    finally:
        if created:
            sql(f'ALTER DATABASE [{name}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{name}];\nGO\n')


if __name__ == '__main__':
    main()
