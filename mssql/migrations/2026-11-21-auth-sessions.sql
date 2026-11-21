-- Server-side login sessions behind short-lived access JWTs. Only refresh-secret hashes are stored.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT ON;
IF OBJECT_ID(N'dbo.auth_sessions',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.auth_sessions (
  id VARCHAR(36) NOT NULL PRIMARY KEY,
  user_id INT NOT NULL REFERENCES dbo.[$(TABLE_USERS)](user_id),
  refresh_hash VARCHAR(64) NOT NULL CONSTRAINT UQ_AuthSession_Refresh UNIQUE,
  previous_hash VARCHAR(64) NULL,
  rotated_at DATETIME2 NULL,
  client_ip VARCHAR(64) NULL,
  mfa_version VARCHAR(36) NULL,
  created_at DATETIME2 NOT NULL,
  expires_at DATETIME2 NOT NULL,
  revoked_at DATETIME2 NULL
 );
 CREATE INDEX IX_AuthSession_User ON dbo.auth_sessions(user_id);
 CREATE INDEX IX_AuthSession_Previous ON dbo.auth_sessions(previous_hash) WHERE previous_hash IS NOT NULL;
 CREATE INDEX IX_AuthSession_Expiry ON dbo.auth_sessions(expires_at);
END;
GO
