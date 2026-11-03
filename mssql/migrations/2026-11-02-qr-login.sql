SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT ON;
IF OBJECT_ID(N'dbo.auth_qr_logins',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.auth_qr_logins (
  id VARCHAR(36) NOT NULL PRIMARY KEY,
  poll_hash VARCHAR(64) NOT NULL,
  approve_hash VARCHAR(64) NOT NULL,
  browser_hash VARCHAR(64) NOT NULL,
  display_code VARCHAR(6) NOT NULL,
  requester_ip VARCHAR(64) NOT NULL,
  device_label VARCHAR(120) NOT NULL,
  status VARCHAR(12) NOT NULL,
  created_at DATETIME2 NOT NULL,
  expires_at DATETIME2 NOT NULL,
  last_poll DATETIME2 NULL,
  user_id INT NULL REFERENCES dbo.[$(TABLE_USERS)](user_id),
  mfa_version VARCHAR(36) NULL,
  failures INT NOT NULL DEFAULT 0
 );
 CREATE INDEX IX_QrLogin_IpCreated ON dbo.auth_qr_logins(requester_ip,created_at);
 CREATE INDEX IX_QrLogin_Expiry ON dbo.auth_qr_logins(expires_at);
 CREATE INDEX IX_QrLogin_User ON dbo.auth_qr_logins(user_id);
END;
GO
