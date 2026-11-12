-- Additive migration. No existing account is linked by email, name or unverified ORCID input.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT ON;
IF COL_LENGTH(N'[$(TABLE_USERS)]',N'orcid') IS NULL
 ALTER TABLE [$(TABLE_USERS)] ADD orcid VARCHAR(19) NULL;
IF COL_LENGTH(N'[$(TABLE_USERS)]',N'orcid_issuer') IS NULL
 ALTER TABLE [$(TABLE_USERS)] ADD orcid_issuer VARCHAR(64) NULL;
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'[$(TABLE_USERS)]') AND name=N'UQ_Users_OrcidIssuer')
 CREATE UNIQUE NONCLUSTERED INDEX UQ_Users_OrcidIssuer ON [$(TABLE_USERS)](orcid_issuer,orcid) WHERE orcid IS NOT NULL AND orcid_issuer IS NOT NULL;
IF OBJECT_ID(N'dbo.auth_orcid_attempts',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.auth_orcid_attempts (
  id VARCHAR(64) NOT NULL PRIMARY KEY,
  browser_hash VARCHAR(64) NOT NULL,
  target_user_id BIGINT NULL,
  workspace_id INT NULL,
  expires_at DATETIME2 NOT NULL,
  consumed BIT NOT NULL
 );
 CREATE INDEX IX_OrcidAttempt_Expiry ON dbo.auth_orcid_attempts(expires_at);
END;
GO
