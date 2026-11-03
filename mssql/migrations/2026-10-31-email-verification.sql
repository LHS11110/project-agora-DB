IF COL_LENGTH(N'[$(TABLE_USERS)]', N'email_verified_at') IS NULL
 ALTER TABLE [$(TABLE_USERS)] ADD email_verified_at DATETIME2 NULL;
GO
-- Registration ownership proof: no account is created until a grant is consumed.
SET XACT_ABORT ON;
IF OBJECT_ID(N'dbo.auth_email_verification',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.auth_email_verification (
  email NVARCHAR(255) NOT NULL PRIMARY KEY,
  challenge_hash VARCHAR(64) NULL,
  code_hash VARCHAR(64) NULL,
  expires_at DATETIME2 NULL,
  attempts INT NOT NULL DEFAULT 0,
  last_sent_at DATETIME2 NULL,
  window_start DATETIME2 NULL,
  sends INT NOT NULL DEFAULT 0,
  grant_hash VARCHAR(64) NULL,
  grant_expires_at DATETIME2 NULL,
  consumed BIT NOT NULL DEFAULT 0
 );
 CREATE INDEX IX_EmailProof_Expires ON dbo.auth_email_verification(expires_at);
END;
IF OBJECT_ID(N'dbo.auth_email_ip_quota',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.auth_email_ip_quota (
  id VARCHAR(64) NOT NULL PRIMARY KEY,
  window_start DATETIME2 NULL,
  sends INT NOT NULL DEFAULT 0
 );
END;
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.auth_email_verification TO [$(DB_USER)];
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.auth_email_ip_quota TO [$(DB_USER)];
GO
