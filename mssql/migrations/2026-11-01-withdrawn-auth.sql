-- Withdrawn users retain historical references but no longer need login credentials.
-- Active and suspended accounts must still have password or OAuth credentials.
SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(N'[$(TABLE_USERS)]') AND name=N'CK_$(TABLE_USERS)_Auth')
    ALTER TABLE [$(TABLE_USERS)] DROP CONSTRAINT [CK_$(TABLE_USERS)_Auth];
ALTER TABLE [$(TABLE_USERS)] WITH CHECK ADD CONSTRAINT [CK_$(TABLE_USERS)_Auth]
    CHECK (status = 'WITHDRAWN' OR password_hash IS NOT NULL OR (oauth_provider IS NOT NULL AND oauth_id IS NOT NULL));
COMMIT TRANSACTION;
GO
