-- ==============================================================================
-- Agora MS SQL Server Database & Schema Initialization
-- sqlcmd 변수 사용:
--   $(DB_NAME), $(DB_USER), $(DB_PASSWORD)
--   $(TABLE_USERS), $(TABLE_REDIS_SERVER), $(TABLE_CANVAS_CACHE), $(TABLE_PYTHON_SERVER)
-- ==============================================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- 1. SQL Server 일반 사용자 로그인 생성 및 비밀번호 동기화
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$(DB_USER)')
BEGIN
    CREATE LOGIN [$(DB_USER)] WITH PASSWORD = '$(DB_PASSWORD)', CHECK_POLICY = OFF;
END
ELSE
BEGIN
    ALTER LOGIN [$(DB_USER)] WITH PASSWORD = '$(DB_PASSWORD)';
END
GO

-- 2. 데이터베이스 생성 (존재하지 않을 경우)
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = '$(DB_NAME)')
BEGIN
    CREATE DATABASE [$(DB_NAME)];
END
GO

-- 3. 데이터베이스 소유자를 지정된 일반 사용자로 설정
EXEC('USE [$(DB_NAME)]; IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ''$(DB_USER)'') DROP USER [$(DB_USER)];');
GO

ALTER AUTHORIZATION ON DATABASE::[$(DB_NAME)] TO [$(DB_USER)];
GO

-- 4. 해당 사용자의 기본 데이터베이스 지정
ALTER LOGIN [$(DB_USER)] WITH DEFAULT_DATABASE = [$(DB_NAME)];
GO

-- 5. 대상 데이터베이스 컨텍스트로 전환
USE [$(DB_NAME)];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- 6. Redis 등록 테이블 (PK: redis_id, UQ: redis_ip, redis_port)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = '$(TABLE_REDIS_SERVER)')
BEGIN
    CREATE TABLE [$(TABLE_REDIS_SERVER)] (
        redis_id    INT IDENTITY(1,1) NOT NULL,
        redis_ip    VARCHAR(45)       NOT NULL,          -- Redis IP 주소 (IPv4/IPv6, 공백 불가)
        redis_port  VARCHAR(10)       NOT NULL,          -- Redis 포트 번호 (공백 불가)
        created_at  DATETIME2         NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT [PK_$(TABLE_REDIS_SERVER)] PRIMARY KEY CLUSTERED (redis_id),
        CONSTRAINT [UQ_$(TABLE_REDIS_SERVER)_ip_port] UNIQUE NONCLUSTERED (redis_ip, redis_port),
        CONSTRAINT [CK_$(TABLE_REDIS_SERVER)_ip] CHECK (LEN(LTRIM(RTRIM(redis_ip))) > 0),
        CONSTRAINT [CK_$(TABLE_REDIS_SERVER)_port] CHECK (LEN(LTRIM(RTRIM(redis_port))) > 0)
    );
END
ELSE
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_$(TABLE_REDIS_SERVER)_ip')
    BEGIN
        ALTER TABLE [$(TABLE_REDIS_SERVER)] ADD CONSTRAINT [CK_$(TABLE_REDIS_SERVER)_ip] CHECK (LEN(LTRIM(RTRIM(redis_ip))) > 0);
    END;
    IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_$(TABLE_REDIS_SERVER)_port')
    BEGIN
        ALTER TABLE [$(TABLE_REDIS_SERVER)] ADD CONSTRAINT [CK_$(TABLE_REDIS_SERVER)_port] CHECK (LEN(LTRIM(RTRIM(redis_port))) > 0);
    END;
END
GO

-- 7. Python Server 등록 테이블 (PK: server_id, UQ: server_ip, server_port)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = '$(TABLE_PYTHON_SERVER)')
BEGIN
    CREATE TABLE [$(TABLE_PYTHON_SERVER)] (
        server_id    INT IDENTITY(1,1) NOT NULL,
        server_ip    VARCHAR(45)       NOT NULL,          -- Python 서버 IP 주소 (IPv4/IPv6, 공백 불가)
        server_port  VARCHAR(10)       NOT NULL,          -- Python 서버 포트 번호 (공백 불가)
        created_at   DATETIME2         NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT [PK_$(TABLE_PYTHON_SERVER)] PRIMARY KEY CLUSTERED (server_id),
        CONSTRAINT [UQ_$(TABLE_PYTHON_SERVER)_ip_port] UNIQUE NONCLUSTERED (server_ip, server_port),
        CONSTRAINT [CK_$(TABLE_PYTHON_SERVER)_ip] CHECK (LEN(LTRIM(RTRIM(server_ip))) > 0),
        CONSTRAINT [CK_$(TABLE_PYTHON_SERVER)_port] CHECK (LEN(LTRIM(RTRIM(server_port))) > 0)
    );
END
ELSE
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_$(TABLE_PYTHON_SERVER)_ip')
    BEGIN
        ALTER TABLE [$(TABLE_PYTHON_SERVER)] ADD CONSTRAINT [CK_$(TABLE_PYTHON_SERVER)_ip] CHECK (LEN(LTRIM(RTRIM(server_ip))) > 0);
    END;
    IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_$(TABLE_PYTHON_SERVER)_port')
    BEGIN
        ALTER TABLE [$(TABLE_PYTHON_SERVER)] ADD CONSTRAINT [CK_$(TABLE_PYTHON_SERVER)_port] CHECK (LEN(LTRIM(RTRIM(server_port))) > 0);
    END;
END
GO

-- 8. 캔버스 캐시 확인 테이블 (PK: canvas_id, FK: redis_server, FK: python_server)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = '$(TABLE_CANVAS_CACHE)')
BEGIN
    CREATE TABLE [$(TABLE_CANVAS_CACHE)] (
        canvas_id   INT           NOT NULL,              -- 캔버스 고유 ID (기본키)
        canvas_name NVARCHAR(255) NOT NULL,              -- 캔버스 이름 (공백 불가)
        redis_ip    VARCHAR(45)   NULL,                  -- Redis IP 주소 (NULL 가능)
        redis_port  VARCHAR(10)   NULL,                  -- Redis 포트 번호 (NULL 가능)
        server_ip   VARCHAR(45)   NULL,                  -- Python 서버 IP 주소 (NULL 가능)
        server_port VARCHAR(10)   NULL,                  -- Python 서버 포트 번호 (NULL 가능)
        is_cached   BIT           NOT NULL DEFAULT 0,     -- 캐시 여부 (NULL 불가, 0: False, 1: True)
        created_at  DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
        updated_at  DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT [PK_$(TABLE_CANVAS_CACHE)] PRIMARY KEY CLUSTERED (canvas_id),
        CONSTRAINT [CK_$(TABLE_CANVAS_CACHE)_name] CHECK (LEN(LTRIM(RTRIM(canvas_name))) > 0),
        CONSTRAINT [FK_$(TABLE_CANVAS_CACHE)_$(TABLE_REDIS_SERVER)] FOREIGN KEY (redis_ip, redis_port)
            REFERENCES [$(TABLE_REDIS_SERVER)] (redis_ip, redis_port)
            ON DELETE SET NULL
            ON UPDATE CASCADE,
        CONSTRAINT [FK_$(TABLE_CANVAS_CACHE)_$(TABLE_PYTHON_SERVER)] FOREIGN KEY (server_ip, server_port)
            REFERENCES [$(TABLE_PYTHON_SERVER)] (server_ip, server_port)
            ON DELETE SET NULL
            ON UPDATE CASCADE
    );
END
ELSE
BEGIN
    IF COL_LENGTH('$(TABLE_CANVAS_CACHE)', 'server_ip') IS NULL
    BEGIN
        ALTER TABLE [$(TABLE_CANVAS_CACHE)] ADD server_ip VARCHAR(45) NULL;
    END;
    IF COL_LENGTH('$(TABLE_CANVAS_CACHE)', 'server_port') IS NULL
    BEGIN
        ALTER TABLE [$(TABLE_CANVAS_CACHE)] ADD server_port VARCHAR(10) NULL;
    END;
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_$(TABLE_CANVAS_CACHE)_$(TABLE_PYTHON_SERVER)')
    BEGIN
        ALTER TABLE [$(TABLE_CANVAS_CACHE)] ADD CONSTRAINT [FK_$(TABLE_CANVAS_CACHE)_$(TABLE_PYTHON_SERVER)]
            FOREIGN KEY (server_ip, server_port)
            REFERENCES [$(TABLE_PYTHON_SERVER)] (server_ip, server_port)
            ON DELETE SET NULL
            ON UPDATE CASCADE;
    END;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_$(TABLE_CANVAS_CACHE)_is_cached' AND object_id = OBJECT_ID('$(TABLE_CANVAS_CACHE)'))
BEGIN
    CREATE NONCLUSTERED INDEX [IX_$(TABLE_CANVAS_CACHE)_is_cached] ON [$(TABLE_CANVAS_CACHE)] (is_cached);
END
GO

-- 9. 회원 테이블 (PK: user_id, UQ: email, 인덱스: oauth, nickname)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = '$(TABLE_USERS)')
BEGIN
    CREATE TABLE [$(TABLE_USERS)] (
        user_id              INT IDENTITY(1,1) NOT NULL,              -- 기본키 클러스터 인덱스
        email                NVARCHAR(255)     NOT NULL,              -- 넌 클러스터 유니크 인덱스
        password_hash        NVARCHAR(255)     NULL,                  -- 비밀번호 해시 (NULL 허용)
        nickname             NVARCHAR(100)     NOT NULL,              -- 닉네임 (공백 불가)
        role                 VARCHAR(20)       NOT NULL DEFAULT 'ROLE_USER', -- 기본 ROLE_USER (관리자 ROLE_ADMIN)
        status               VARCHAR(20)       NOT NULL DEFAULT 'ACTIVE',    -- ACTIVE, SUSPENDED, WITHDRAWN
        oauth_provider       VARCHAR(50)       NULL,                  -- OAuth 제공자 (NULL 가능)
        oauth_id             NVARCHAR(255)     NULL,                  -- 제공자별 고유 회원 식별자 (NULL 가능)
        last_login_at        DATETIME2         NULL,                  -- 마지막 로그인 시간 (NULL 가능)
        password_changed_at  DATETIME2         NULL,                  -- 비밀번호 변경 시간 (NULL 가능)
        created_at           DATETIME2         NOT NULL DEFAULT SYSDATETIME(),
        updated_at           DATETIME2         NOT NULL DEFAULT SYSDATETIME(),
        CONSTRAINT [PK_$(TABLE_USERS)] PRIMARY KEY CLUSTERED (user_id),
        CONSTRAINT [UQ_$(TABLE_USERS)_Email] UNIQUE NONCLUSTERED (email),
        CONSTRAINT [CK_$(TABLE_USERS)_Status] CHECK (status IN ('ACTIVE', 'SUSPENDED', 'WITHDRAWN')),
        CONSTRAINT [CK_$(TABLE_USERS)_Role] CHECK (role IN ('ROLE_USER', 'ROLE_ADMIN')),
        CONSTRAINT [CK_$(TABLE_USERS)_Nickname] CHECK (LEN(LTRIM(RTRIM(nickname))) > 0)
    );
END
GO

-- 회원 테이블 비 클러스터 인덱스 생성
-- (1) (oauth_provider, oauth_id) - oauth_provider가 NULL이 아닌 것만 인덱싱
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_$(TABLE_USERS)_OAuth' AND object_id = OBJECT_ID('$(TABLE_USERS)'))
BEGIN
    CREATE NONCLUSTERED INDEX [IX_$(TABLE_USERS)_OAuth] ON [$(TABLE_USERS)] (oauth_provider, oauth_id)
    WHERE oauth_provider IS NOT NULL;
END
GO

-- (2) (nickname)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_$(TABLE_USERS)_Nickname' AND object_id = OBJECT_ID('$(TABLE_USERS)'))
BEGIN
    CREATE NONCLUSTERED INDEX [IX_$(TABLE_USERS)_Nickname] ON [$(TABLE_USERS)] (nickname);
END
GO

-- 10. 데이터베이스 소유자 및 생성된 테이블 목록 확인
SELECT name AS database_name, SUSER_SNAME(owner_sid) AS owner_name FROM sys.databases WHERE name = '$(DB_NAME)';
SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE';
GO
