-- Separate IRADE workspaces from Agora Canvas metadata and durable runtime cleanup queues.
SET XACT_ABORT ON;

IF OBJECT_ID(N'dbo.workspace_info', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.workspace_info (
        workspace_id  INT       IDENTITY(1,1) NOT NULL,
        redis_id      INT       NULL,
        cpp_server_id INT       NULL,
        is_cached     BIT       NOT NULL DEFAULT 0,
        created_at    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        updated_at    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_workspace_info PRIMARY KEY CLUSTERED (workspace_id),
        CONSTRAINT FK_workspace_info_redis_server FOREIGN KEY (redis_id)
            REFERENCES dbo.redis_server (redis_id)
            ON DELETE NO ACTION
            ON UPDATE NO ACTION,
        CONSTRAINT FK_workspace_info_cpp_server FOREIGN KEY (cpp_server_id)
            REFERENCES dbo.cpp_server (server_id)
            ON DELETE NO ACTION
            ON UPDATE NO ACTION
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_workspace_info_cpp_server'
      AND object_id = OBJECT_ID(N'dbo.workspace_info')
)
    CREATE NONCLUSTERED INDEX IX_workspace_info_cpp_server
        ON dbo.workspace_info (cpp_server_id);
GO

IF OBJECT_ID(N'dbo.workspace_runtime_cleanup', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.workspace_runtime_cleanup (
        workspace_id     INT       NOT NULL PRIMARY KEY,
        created_at       DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        attempt_count    INT       NOT NULL DEFAULT 0,
        next_attempt_at  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_workspace_runtime_cleanup_due
        ON dbo.workspace_runtime_cleanup (next_attempt_at, workspace_id);
END;
GO

IF DATABASE_PRINCIPAL_ID('agora_runtime') IS NOT NULL
BEGIN
    GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.workspace_info TO [agora_runtime];
    GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.workspace_runtime_cleanup TO [agora_runtime];
END;
GO
