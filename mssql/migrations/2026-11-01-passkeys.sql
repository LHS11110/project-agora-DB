-- WebAuthn public credentials only. Private keys and biometrics never reach this database.
SET XACT_ABORT ON;
IF OBJECT_ID(N'dbo.user_passkeys', N'U') IS NULL
BEGIN
 CREATE TABLE dbo.user_passkeys (
  id VARCHAR(36) NOT NULL PRIMARY KEY,
  credential_hash VARCHAR(64) NOT NULL UNIQUE,
  credential_id VARCHAR(2048) NOT NULL,
  user_id INT NOT NULL REFERENCES dbo.[$(TABLE_USERS)](user_id),
  user_handle VARCHAR(64) NOT NULL,
  public_key VARCHAR(4096) NOT NULL,
  signature_count BIGINT NOT NULL,
  name NVARCHAR(80) NOT NULL,
  created_at DATETIME2 NOT NULL,
  last_used_at DATETIME2 NULL
 );
 CREATE INDEX IX_user_passkeys_user ON dbo.user_passkeys(user_id,created_at);
 CREATE INDEX IX_user_passkeys_handle ON dbo.user_passkeys(user_handle);
END;
IF OBJECT_ID(N'dbo.auth_passkey_challenges', N'U') IS NULL
BEGIN
 CREATE TABLE dbo.auth_passkey_challenges (
  id VARCHAR(64) NOT NULL PRIMARY KEY,
  purpose VARCHAR(12) NOT NULL,
  user_id INT NULL REFERENCES dbo.[$(TABLE_USERS)](user_id),
  client_ip VARCHAR(64) NOT NULL,
  request_json VARCHAR(MAX) NOT NULL,
  created_at DATETIME2 NOT NULL,
  expires_at DATETIME2 NOT NULL,
  used BIT NOT NULL DEFAULT 0
 );
 CREATE INDEX IX_passkey_challenge_expiry ON dbo.auth_passkey_challenges(expires_at);
 CREATE INDEX IX_passkey_challenge_ip ON dbo.auth_passkey_challenges(client_ip,created_at);
END;
GO
