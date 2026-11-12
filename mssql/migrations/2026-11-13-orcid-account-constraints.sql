-- Permit authenticated ORCID-only accounts while preserving email requirements
-- for ordinary password/social accounts and the existing erasure exception.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT ON;
IF COL_LENGTH(N'[$(TABLE_USERS)]',N'orcid') IS NULL
 OR COL_LENGTH(N'[$(TABLE_USERS)]',N'orcid_issuer') IS NULL
 THROW 51000, 'Apply the IRADE ORCID identity migration first', 1;
BEGIN TRANSACTION;
IF EXISTS(SELECT 1 FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(N'[$(TABLE_USERS)]') AND name=N'CK_$(TABLE_USERS)_Auth')
 ALTER TABLE [$(TABLE_USERS)] DROP CONSTRAINT [CK_$(TABLE_USERS)_Auth];
IF EXISTS(SELECT 1 FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(N'[$(TABLE_USERS)]') AND name=N'CK_$(TABLE_USERS)_EmailRequired')
 ALTER TABLE [$(TABLE_USERS)] DROP CONSTRAINT [CK_$(TABLE_USERS)_EmailRequired];
ALTER TABLE [$(TABLE_USERS)] WITH CHECK ADD CONSTRAINT [CK_$(TABLE_USERS)_Auth]
 CHECK (
  status='WITHDRAWN' OR password_hash IS NOT NULL
  OR (oauth_provider IS NOT NULL AND oauth_id IS NOT NULL)
  OR (orcid IS NOT NULL AND LEN(orcid)=19 AND orcid_issuer IS NOT NULL
      AND orcid_issuer IN ('https://orcid.org','https://sandbox.orcid.org'))
 );
ALTER TABLE [$(TABLE_USERS)] WITH CHECK ADD CONSTRAINT [CK_$(TABLE_USERS)_EmailRequired]
 CHECK (
  status='WITHDRAWN' OR email IS NOT NULL
  OR (orcid IS NOT NULL AND LEN(orcid)=19 AND orcid_issuer IS NOT NULL
      AND orcid_issuer IN ('https://orcid.org','https://sandbox.orcid.org'))
 );
COMMIT TRANSACTION;
GO
