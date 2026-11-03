-- Irreversibly anonymize withdrawn accounts; active accounts are not modified.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF EXISTS(SELECT 1 FROM sys.key_constraints WHERE parent_object_id=OBJECT_ID(N'[$(TABLE_USERS)]') AND name=N'UQ_Users_Email')
 ALTER TABLE [$(TABLE_USERS)] DROP CONSTRAINT [UQ_Users_Email];
IF EXISTS(SELECT 1 FROM sys.key_constraints WHERE parent_object_id=OBJECT_ID(N'[$(TABLE_USERS)]') AND name=N'UQ_$(TABLE_USERS)_Email')
 ALTER TABLE [$(TABLE_USERS)] DROP CONSTRAINT [UQ_$(TABLE_USERS)_Email];
IF EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'[$(TABLE_USERS)]') AND name=N'UQ_Users_Email')
 DROP INDEX [UQ_Users_Email] ON [$(TABLE_USERS)];
ALTER TABLE [$(TABLE_USERS)] ALTER COLUMN email NVARCHAR(255) NULL;
CREATE UNIQUE NONCLUSTERED INDEX [UQ_Users_Email] ON [$(TABLE_USERS)](email) WHERE email IS NOT NULL;
IF OBJECT_ID(N'dbo.auth_email_verification',N'U') IS NOT NULL
 DELETE p FROM dbo.auth_email_verification p JOIN [$(TABLE_USERS)] u ON p.email=u.email WHERE u.status='WITHDRAWN';
IF OBJECT_ID(N'dbo.auth_mfa_challenges',N'U') IS NOT NULL
 DELETE p FROM dbo.auth_mfa_challenges p JOIN [$(TABLE_USERS)] u ON p.user_id=u.user_id WHERE u.status='WITHDRAWN';
IF OBJECT_ID(N'dbo.user_mfa',N'U') IS NOT NULL
 DELETE p FROM dbo.user_mfa p JOIN [$(TABLE_USERS)] u ON p.user_id=u.user_id WHERE u.status='WITHDRAWN';
IF OBJECT_ID(N'dbo.auth_passkey_challenges',N'U') IS NOT NULL
 DELETE p FROM dbo.auth_passkey_challenges p JOIN [$(TABLE_USERS)] u ON p.user_id=u.user_id WHERE u.status='WITHDRAWN';
IF OBJECT_ID(N'dbo.user_passkeys',N'U') IS NOT NULL
 DELETE p FROM dbo.user_passkeys p JOIN [$(TABLE_USERS)] u ON p.user_id=u.user_id WHERE u.status='WITHDRAWN';
IF OBJECT_ID(N'dbo.user_sessions',N'U') IS NOT NULL
 DELETE p FROM dbo.user_sessions p JOIN [$(TABLE_USERS)] u ON p.user_id=u.user_id WHERE u.status='WITHDRAWN';
UPDATE [$(TABLE_USERS)] SET email=NULL,password_hash=NULL,oauth_provider=NULL,oauth_id=NULL,
 email_verified_at=NULL,password_changed_at=NULL,nickname=N'삭제된 계정',tag_number=user_id,role='ROLE_USER'
 WHERE status='WITHDRAWN';
IF NOT EXISTS(SELECT 1 FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(N'[$(TABLE_USERS)]') AND name=N'CK_$(TABLE_USERS)_EmailRequired')
 ALTER TABLE [$(TABLE_USERS)] WITH CHECK ADD CONSTRAINT [CK_$(TABLE_USERS)_EmailRequired] CHECK(status='WITHDRAWN' OR email IS NOT NULL);
IF COL_LENGTH(N'[$(TABLE_USERS)]',N'profile_image_url') IS NOT NULL
 EXEC(N'UPDATE [$(TABLE_USERS)] SET profile_image_url=NULL WHERE status=''WITHDRAWN''');
IF OBJECT_ID(N'dbo.auth_qr_logins',N'U') IS NOT NULL
 EXEC(N'DELETE p FROM dbo.auth_qr_logins p JOIN [$(TABLE_USERS)] u ON p.user_id=u.user_id WHERE u.status=''WITHDRAWN''');
COMMIT TRANSACTION;
GO
