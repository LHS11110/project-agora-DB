IF COL_LENGTH(N'dbo.[$(TABLE_USERS)]', N'adult_verified_at') IS NULL
    ALTER TABLE dbo.[$(TABLE_USERS)] ADD adult_verified_at DATETIME2 NULL;
IF COL_LENGTH(N'dbo.[$(TABLE_USERS)]', N'adult_verification_attempt') IS NULL
    ALTER TABLE dbo.[$(TABLE_USERS)] ADD adult_verification_attempt VARCHAR(36) NULL;
IF COL_LENGTH(N'dbo.[$(TABLE_USERS)]', N'adult_verification_expires_at') IS NULL
    ALTER TABLE dbo.[$(TABLE_USERS)] ADD adult_verification_expires_at DATETIME2 NULL;
GO
