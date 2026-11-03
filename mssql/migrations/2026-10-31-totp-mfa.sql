-- Optional account TOTP; seeds encrypted by application, recovery codes hashed.
SET XACT_ABORT ON;
IF OBJECT_ID(N'dbo.user_mfa', N'U') IS NULL
BEGIN
 CREATE TABLE dbo.user_mfa (
  user_id INT NOT NULL PRIMARY KEY REFERENCES [$(TABLE_USERS)](user_id),
  enabled BIT NOT NULL DEFAULT 0,
  secret VARCHAR(512) NULL,
  pending_secret VARCHAR(512) NULL,
  pending_expires DATETIME2 NULL,
  last_step BIGINT NOT NULL DEFAULT -1,
  version VARCHAR(36) NULL,
  recovery_hashes VARCHAR(2048) NULL,
  failures INT NOT NULL DEFAULT 0,
  locked_until DATETIME2 NULL,
  CONSTRAINT CK_UserMfa_Enabled CHECK (enabled=0 OR (secret IS NOT NULL AND version IS NOT NULL))
 );
END;
IF OBJECT_ID(N'dbo.auth_mfa_challenges', N'U') IS NULL
BEGIN
 CREATE TABLE dbo.auth_mfa_challenges (
  id VARCHAR(64) NOT NULL PRIMARY KEY,
  user_id INT NOT NULL REFERENCES [$(TABLE_USERS)](user_id),
  version VARCHAR(36) NULL,
  client_ip VARCHAR(64) NULL,
  expires_at DATETIME2 NULL,
  used BIT NOT NULL DEFAULT 0
 );
 CREATE INDEX IX_MfaChallenge_Expires ON dbo.auth_mfa_challenges(expires_at);
END;
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.user_mfa TO [$(DB_USER)];
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.auth_mfa_challenges TO [$(DB_USER)];
GO
