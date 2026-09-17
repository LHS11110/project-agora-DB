-- ==============================================================================
-- Agora MS SQL Server Database & Schema Initialization
-- sqlcmd 변수 사용:
--   $(DB_NAME), $(DB_USER), $(DB_PASSWORD)
--   $(TABLE_USERS), $(TABLE_REDIS_SERVER), $(TABLE_CPP_SERVER), $(TABLE_CANVAS_INFO)
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
        redis_id      INT IDENTITY(1,1) NOT NULL,
        redis_ip      VARCHAR(45)       NOT NULL,          -- Redis IP 주소 (IPv4/IPv6, 공백 불가)
        redis_port    VARCHAR(10)       NOT NULL,          -- Redis 포트 번호 (공백 불가)
        is_activated  BIT               NOT NULL DEFAULT 0, -- 활성화 여부
        created_at    DATETIME2         NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT [PK_$(TABLE_REDIS_SERVER)] PRIMARY KEY CLUSTERED (redis_id),
        CONSTRAINT [UQ_$(TABLE_REDIS_SERVER)_ip_port] UNIQUE NONCLUSTERED (redis_ip, redis_port),
        CONSTRAINT [CK_$(TABLE_REDIS_SERVER)_ip] CHECK (LEN(LTRIM(RTRIM(redis_ip))) > 0),
        CONSTRAINT [CK_$(TABLE_REDIS_SERVER)_port] CHECK (LEN(LTRIM(RTRIM(redis_port))) > 0)
    );
END
ELSE
BEGIN
    IF COL_LENGTH('$(TABLE_REDIS_SERVER)', 'is_activated') IS NULL
    BEGIN
        ALTER TABLE [$(TABLE_REDIS_SERVER)] ADD is_activated BIT NOT NULL DEFAULT 0;
    END;
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

-- 7. C++ 실시간 서버 인스턴스 등록 테이블 (PK: server_id, UQ: server_ip, server_port)

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = '$(TABLE_CPP_SERVER)')
BEGIN
    CREATE TABLE [$(TABLE_CPP_SERVER)] (
        server_id     INT IDENTITY(1,1) NOT NULL,
        server_ip     VARCHAR(45)       NOT NULL,          -- C++ 실시간 서버 IP 주소 (IPv4/IPv6, 공백 불가)
        server_port   VARCHAR(10)       NOT NULL,          -- C++ 실시간 서버 포트 번호 (공백 불가)
        ws_port       VARCHAR(10)       NOT NULL,          -- C++ 웹소켓 포트 번호
        is_activated  BIT               NOT NULL DEFAULT 0, -- 활성화 여부
        created_at    DATETIME2         NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT [PK_$(TABLE_CPP_SERVER)] PRIMARY KEY CLUSTERED (server_id),
        CONSTRAINT [UQ_$(TABLE_CPP_SERVER)_ip_port] UNIQUE NONCLUSTERED (server_ip, server_port, ws_port),
        CONSTRAINT [CK_$(TABLE_CPP_SERVER)_ip] CHECK (LEN(LTRIM(RTRIM(server_ip))) > 0),
        CONSTRAINT [CK_$(TABLE_CPP_SERVER)_port] CHECK (LEN(LTRIM(RTRIM(server_port))) > 0),
        CONSTRAINT [CK_$(TABLE_CPP_SERVER)_ws_port] CHECK (LEN(LTRIM(RTRIM(ws_port))) > 0)
    );
END
ELSE
BEGIN
    IF COL_LENGTH('$(TABLE_CPP_SERVER)', 'is_activated') IS NULL
    BEGIN
        ALTER TABLE [$(TABLE_CPP_SERVER)] ADD is_activated BIT NOT NULL DEFAULT 0;
    END;
    IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_$(TABLE_CPP_SERVER)_ip')
    BEGIN
        ALTER TABLE [$(TABLE_CPP_SERVER)] ADD CONSTRAINT [CK_$(TABLE_CPP_SERVER)_ip] CHECK (LEN(LTRIM(RTRIM(server_ip))) > 0);
    END;
    IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_$(TABLE_CPP_SERVER)_port')
    BEGIN
        ALTER TABLE [$(TABLE_CPP_SERVER)] ADD CONSTRAINT [CK_$(TABLE_CPP_SERVER)_port] CHECK (LEN(LTRIM(RTRIM(server_port))) > 0),
        CONSTRAINT [CK_$(TABLE_CPP_SERVER)_ws_port] CHECK (LEN(LTRIM(RTRIM(ws_port))) > 0);
    END;
END
GO

-- 8. 회원 테이블 (PK: user_id, UQ: email, 인덱스: oauth, nickname)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = '$(TABLE_USERS)')
BEGIN
    CREATE TABLE [$(TABLE_USERS)] (
        user_id              INT IDENTITY(1,1) NOT NULL,              -- 기본키 자동 증가 클러스터드 인덱스
        email                NVARCHAR(255)     NOT NULL,              -- 넌클러스터드 유니크 인덱스 UQ_Users_Email
        password_hash        NVARCHAR(255)     NULL,                  -- 비밀번호 해시 (NULL 허용)
        nickname             NVARCHAR(100)     NOT NULL,              -- 닉네임 (중복 가능, 공백 불가)
        tag_number           INT               NOT NULL DEFAULT 0,    -- 닉네임 유일성 식별용 정수값
        role                 NVARCHAR(10)      NOT NULL DEFAULT 'ROLE_USER', -- 기본 ROLE_USER (관리자 ROLE_ADMIN)
        status               NVARCHAR(20)      NOT NULL DEFAULT 'ACTIVE',    -- ACTIVE, SUSPENDED, WITHDRAWN
        oauth_provider       NVARCHAR(50)      NULL,                  -- OAuth 제공자 (NULL 가능)
        oauth_id             NVARCHAR(255)     NULL,                  -- 제공자별 고유 회원 식별자 (NULL 가능)
        password_changed_at  DATETIME2         NULL,                  -- 비밀번호 변경 시간 (NULL 가능)
        created_at           DATETIME2         NOT NULL DEFAULT SYSUTCDATETIME(),
        updated_at           DATETIME2         NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT [PK_$(TABLE_USERS)] PRIMARY KEY CLUSTERED (user_id),
        CONSTRAINT [UQ_Users_Email] UNIQUE NONCLUSTERED (email),
        CONSTRAINT [UQ_Users_Nickname_TagNumber] UNIQUE NONCLUSTERED (nickname, tag_number),
        CONSTRAINT [CK_$(TABLE_USERS)_Status] CHECK (status IN ('ACTIVE', 'SUSPENDED', 'WITHDRAWN')),
        CONSTRAINT [CK_$(TABLE_USERS)_Role] CHECK (role IN ('ROLE_USER', 'ROLE_ADMIN')),
        CONSTRAINT [CK_$(TABLE_USERS)_Nickname] CHECK (LEN(LTRIM(RTRIM(nickname))) > 0),
        CONSTRAINT [CK_$(TABLE_USERS)_Auth] CHECK (password_hash IS NOT NULL OR (oauth_provider IS NOT NULL AND oauth_id IS NOT NULL))
    );
END
ELSE
BEGIN
    -- 기존 세션 관련 컬럼 제거
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_$(TABLE_USERS)_$(TABLE_CPP_SERVER)')
    BEGIN
        ALTER TABLE [$(TABLE_USERS)] DROP CONSTRAINT [FK_$(TABLE_USERS)_$(TABLE_CPP_SERVER)];
    END;
    IF COL_LENGTH('$(TABLE_USERS)', 'cpp_server_id') IS NOT NULL
    BEGIN
        ALTER TABLE [$(TABLE_USERS)] DROP COLUMN cpp_server_id;
    END;
    IF COL_LENGTH('$(TABLE_USERS)', 'is_accessed') IS NOT NULL
    BEGIN
        ALTER TABLE [$(TABLE_USERS)] DROP COLUMN is_accessed;
    END;
    IF COL_LENGTH('$(TABLE_USERS)', 'last_login_at') IS NOT NULL
    BEGIN
        ALTER TABLE [$(TABLE_USERS)] DROP COLUMN last_login_at;
    END;

    -- tag_number 컬럼 및 고유 제약조건 추가
    IF COL_LENGTH('$(TABLE_USERS)', 'tag_number') IS NULL
    BEGIN
        ALTER TABLE [$(TABLE_USERS)] ADD tag_number INT NOT NULL DEFAULT 0;
    END;
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_Users_Nickname_TagNumber' AND object_id = OBJECT_ID('$(TABLE_USERS)'))
    BEGIN
        ALTER TABLE [$(TABLE_USERS)] ADD CONSTRAINT [UQ_Users_Nickname_TagNumber] UNIQUE NONCLUSTERED (nickname, tag_number);
    END;

    -- 인증 무결성 제약조건 추가
    IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_$(TABLE_USERS)_Auth')
    BEGIN
        ALTER TABLE [$(TABLE_USERS)] ADD CONSTRAINT [CK_$(TABLE_USERS)_Auth] CHECK (password_hash IS NOT NULL OR (oauth_provider IS NOT NULL AND oauth_id IS NOT NULL));
    END;
    
    -- role 제약조건 임시 해제 후 타입 변경 및 제약조건 재설정
    DECLARE @def_name NVARCHAR(128);
    SELECT @def_name = d.name
    FROM sys.default_constraints d
    JOIN sys.columns c ON d.parent_object_id = c.object_id AND d.parent_column_id = c.column_id
    WHERE d.parent_object_id = OBJECT_ID('$(TABLE_USERS)') AND c.name = 'role';
    IF @def_name IS NOT NULL
        EXEC('ALTER TABLE [$(TABLE_USERS)] DROP CONSTRAINT [' + @def_name + '];');

    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_$(TABLE_USERS)_Role')
        ALTER TABLE [$(TABLE_USERS)] DROP CONSTRAINT [CK_$(TABLE_USERS)_Role];

    ALTER TABLE [$(TABLE_USERS)] ALTER COLUMN role NVARCHAR(10) NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.default_constraints d JOIN sys.columns c ON d.parent_object_id = c.object_id AND d.parent_column_id = c.column_id WHERE d.parent_object_id = OBJECT_ID('$(TABLE_USERS)') AND c.name = 'role')
        ALTER TABLE [$(TABLE_USERS)] ADD CONSTRAINT [DF_$(TABLE_USERS)_role] DEFAULT 'ROLE_USER' FOR role;
    IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_$(TABLE_USERS)_Role')
        ALTER TABLE [$(TABLE_USERS)] ADD CONSTRAINT [CK_$(TABLE_USERS)_Role] CHECK (role IN ('ROLE_USER', 'ROLE_ADMIN'));

    -- status 제약조건 임시 해제 후 타입 변경 및 제약조건 재설정
    SELECT @def_name = d.name
    FROM sys.default_constraints d
    JOIN sys.columns c ON d.parent_object_id = c.object_id AND d.parent_column_id = c.column_id
    WHERE d.parent_object_id = OBJECT_ID('$(TABLE_USERS)') AND c.name = 'status';
    IF @def_name IS NOT NULL
        EXEC('ALTER TABLE [$(TABLE_USERS)] DROP CONSTRAINT [' + @def_name + '];');

    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_$(TABLE_USERS)_Status')
        ALTER TABLE [$(TABLE_USERS)] DROP CONSTRAINT [CK_$(TABLE_USERS)_Status];

    ALTER TABLE [$(TABLE_USERS)] ALTER COLUMN status NVARCHAR(20) NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.default_constraints d JOIN sys.columns c ON d.parent_object_id = c.object_id AND d.parent_column_id = c.column_id WHERE d.parent_object_id = OBJECT_ID('$(TABLE_USERS)') AND c.name = 'status')
        ALTER TABLE [$(TABLE_USERS)] ADD CONSTRAINT [DF_$(TABLE_USERS)_status] DEFAULT 'ACTIVE' FOR status;
    IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_$(TABLE_USERS)_Status')
        ALTER TABLE [$(TABLE_USERS)] ADD CONSTRAINT [CK_$(TABLE_USERS)_Status] CHECK (status IN ('ACTIVE', 'SUSPENDED', 'WITHDRAWN'));

    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_$(TABLE_USERS)_OAuth' AND object_id = OBJECT_ID('$(TABLE_USERS)'))
        DROP INDEX [IX_$(TABLE_USERS)_OAuth] ON [$(TABLE_USERS)];

    ALTER TABLE [$(TABLE_USERS)] ALTER COLUMN oauth_provider NVARCHAR(50) NULL;

    -- UQ_Users_Email 인덱스/제약조건 이름 동기화
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_Users_Email' AND object_id = OBJECT_ID('$(TABLE_USERS)'))
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_$(TABLE_USERS)_Email' AND object_id = OBJECT_ID('$(TABLE_USERS)'))
        BEGIN
            EXEC sp_rename '$(TABLE_USERS).UQ_$(TABLE_USERS)_Email', 'UQ_Users_Email', 'INDEX';
        END
        ELSE
        BEGIN
            ALTER TABLE [$(TABLE_USERS)] ADD CONSTRAINT [UQ_Users_Email] UNIQUE NONCLUSTERED (email);
        END
    END;
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

-- 8-2. 세션 테이블 (PK: user_id)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'user_sessions')
BEGIN
    CREATE TABLE [user_sessions] (
        user_id              INT               NOT NULL,
        cpp_server_id        INT               NULL,
        is_accessed          BIT               NOT NULL DEFAULT 0,
        last_login_at        DATETIME2         NULL,
        updated_at           DATETIME2         NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT [PK_user_sessions] PRIMARY KEY CLUSTERED (user_id),
        CONSTRAINT [FK_user_sessions_users] FOREIGN KEY (user_id) REFERENCES [$(TABLE_USERS)] (user_id) ON DELETE NO ACTION ON UPDATE NO ACTION,
        CONSTRAINT [FK_user_sessions_$(TABLE_CPP_SERVER)] FOREIGN KEY (cpp_server_id) REFERENCES [$(TABLE_CPP_SERVER)] (server_id) ON DELETE NO ACTION ON UPDATE NO ACTION
    );
END
ELSE
BEGIN
    IF COL_LENGTH('user_sessions', 'is_accessed') IS NULL
    BEGIN
        ALTER TABLE [user_sessions] ADD is_accessed BIT NOT NULL DEFAULT 0;
    END;
END
GO

-- 9. 캔버스 정보 테이블 (캔버스 서버 할당 및 상태 관리, PK: canvas_id, FK: redis_server(redis_id), FK: cpp_server(server_id))
-- 기존 canvas_cache 테이블이 존재하고 신규 테이블명과 다를 경우 처리
IF EXISTS (SELECT 1 FROM sys.tables WHERE name = 'canvas_cache')
   AND NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = '$(TABLE_CANVAS_INFO)')
BEGIN
    EXEC sp_rename 'canvas_cache', '$(TABLE_CANVAS_INFO)';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = '$(TABLE_CANVAS_INFO)')
BEGIN
    CREATE TABLE [$(TABLE_CANVAS_INFO)] (
        canvas_id     INT           IDENTITY(1,1) NOT NULL, -- 캔버스 고유 ID (PK, 클러스터드 인덱스)
        redis_id      INT           NULL,                  -- Redis 서버 ID (FK → redis_server.redis_id)
        cpp_server_id INT           NULL,                  -- C++ 실시간 서버 ID (FK → cpp_server.server_id)
        is_cached     BIT           NOT NULL DEFAULT 0,    -- 캐시 여부 (NULL 불가, 0: False, 1: True)
        created_at    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
        updated_at    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT [PK_$(TABLE_CANVAS_INFO)] PRIMARY KEY CLUSTERED (canvas_id),
        CONSTRAINT [FK_$(TABLE_CANVAS_INFO)_$(TABLE_REDIS_SERVER)] FOREIGN KEY (redis_id)
            REFERENCES [$(TABLE_REDIS_SERVER)] (redis_id)
            ON DELETE NO ACTION
            ON UPDATE NO ACTION,
        CONSTRAINT [FK_$(TABLE_CANVAS_INFO)_$(TABLE_CPP_SERVER)] FOREIGN KEY (cpp_server_id)
            REFERENCES [$(TABLE_CPP_SERVER)] (server_id)
            ON DELETE NO ACTION
            ON UPDATE NO ACTION
    );
END
ELSE
BEGIN
    -- 기존 스키마에 남아있던 불필요한 제약조건 및 컬럼 정리 (canvas_name, user_id)
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_$(TABLE_CANVAS_INFO)_$(TABLE_USERS)')
    BEGIN
        ALTER TABLE [$(TABLE_CANVAS_INFO)] DROP CONSTRAINT [FK_$(TABLE_CANVAS_INFO)_$(TABLE_USERS)];
    END;
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_$(TABLE_CANVAS_INFO)_user_id' AND object_id = OBJECT_ID('$(TABLE_CANVAS_INFO)'))
    BEGIN
        DROP INDEX [IX_$(TABLE_CANVAS_INFO)_user_id] ON [$(TABLE_CANVAS_INFO)];
    END;
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_$(TABLE_CANVAS_INFO)_name')
    BEGIN
        ALTER TABLE [$(TABLE_CANVAS_INFO)] DROP CONSTRAINT [CK_$(TABLE_CANVAS_INFO)_name];
    END;
    IF COL_LENGTH('$(TABLE_CANVAS_INFO)', 'canvas_name') IS NOT NULL
    BEGIN
        ALTER TABLE [$(TABLE_CANVAS_INFO)] DROP COLUMN canvas_name;
    END;
    IF COL_LENGTH('$(TABLE_CANVAS_INFO)', 'user_id') IS NOT NULL
    BEGIN
        ALTER TABLE [$(TABLE_CANVAS_INFO)] DROP COLUMN user_id;
    END;

    -- 기존 복합 자연키 FK → 대리키 FK 마이그레이션 (redis_ip/port → redis_id)
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_$(TABLE_CANVAS_INFO)_$(TABLE_REDIS_SERVER)')
    BEGIN
        ALTER TABLE [$(TABLE_CANVAS_INFO)] DROP CONSTRAINT [FK_$(TABLE_CANVAS_INFO)_$(TABLE_REDIS_SERVER)];
    END;
    IF COL_LENGTH('$(TABLE_CANVAS_INFO)', 'redis_ip') IS NOT NULL
    BEGIN
        IF COL_LENGTH('$(TABLE_CANVAS_INFO)', 'redis_id') IS NULL
        BEGIN
            ALTER TABLE [$(TABLE_CANVAS_INFO)] ADD redis_id INT NULL;
            EXEC('
                UPDATE c SET c.redis_id = r.redis_id
                FROM [$(TABLE_CANVAS_INFO)] c
                INNER JOIN [$(TABLE_REDIS_SERVER)] r ON c.redis_ip = r.redis_ip AND c.redis_port = r.redis_port
                WHERE c.redis_ip IS NOT NULL AND c.redis_port IS NOT NULL
            ');
        END;
        ALTER TABLE [$(TABLE_CANVAS_INFO)] DROP COLUMN redis_ip;
        ALTER TABLE [$(TABLE_CANVAS_INFO)] DROP COLUMN redis_port;
    END;
    IF COL_LENGTH('$(TABLE_CANVAS_INFO)', 'redis_id') IS NULL
    BEGIN
        ALTER TABLE [$(TABLE_CANVAS_INFO)] ADD redis_id INT NULL;
    END;
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_$(TABLE_CANVAS_INFO)_$(TABLE_REDIS_SERVER)')
    BEGIN
        ALTER TABLE [$(TABLE_CANVAS_INFO)] ADD CONSTRAINT [FK_$(TABLE_CANVAS_INFO)_$(TABLE_REDIS_SERVER)]
            FOREIGN KEY (redis_id) REFERENCES [$(TABLE_REDIS_SERVER)] (redis_id)
            ON DELETE NO ACTION ON UPDATE NO ACTION;
    END;

    -- 기존 복합 자연키 FK → 대리키 FK 마이그레이션 (server_ip/port → cpp_server_id)
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_$(TABLE_CANVAS_INFO)_$(TABLE_CPP_SERVER)')
    BEGIN
        ALTER TABLE [$(TABLE_CANVAS_INFO)] DROP CONSTRAINT [FK_$(TABLE_CANVAS_INFO)_$(TABLE_CPP_SERVER)];
    END;

    IF COL_LENGTH('$(TABLE_CANVAS_INFO)', 'server_ip') IS NOT NULL
    BEGIN
        IF COL_LENGTH('$(TABLE_CANVAS_INFO)', 'cpp_server_id') IS NULL
        BEGIN
            ALTER TABLE [$(TABLE_CANVAS_INFO)] ADD cpp_server_id INT NULL;
            EXEC('
                UPDATE c SET c.cpp_server_id = s.server_id
                FROM [$(TABLE_CANVAS_INFO)] c
                INNER JOIN [$(TABLE_CPP_SERVER)] s ON c.server_ip = s.server_ip AND c.server_port = s.server_port
                WHERE c.server_ip IS NOT NULL AND c.server_port IS NOT NULL
            ');
        END;
        ALTER TABLE [$(TABLE_CANVAS_INFO)] DROP COLUMN server_ip;
        ALTER TABLE [$(TABLE_CANVAS_INFO)] DROP COLUMN server_port;
    END;
    IF COL_LENGTH('$(TABLE_CANVAS_INFO)', 'cpp_server_id') IS NULL
    BEGIN
        ALTER TABLE [$(TABLE_CANVAS_INFO)] ADD cpp_server_id INT NULL;
    END;
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_$(TABLE_CANVAS_INFO)_$(TABLE_CPP_SERVER)')
    BEGIN
        ALTER TABLE [$(TABLE_CANVAS_INFO)] ADD CONSTRAINT [FK_$(TABLE_CANVAS_INFO)_$(TABLE_CPP_SERVER)]
            FOREIGN KEY (cpp_server_id) REFERENCES [$(TABLE_CPP_SERVER)] (server_id)
            ON DELETE NO ACTION ON UPDATE NO ACTION;
    END;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_$(TABLE_CANVAS_INFO)_is_cached' AND object_id = OBJECT_ID('$(TABLE_CANVAS_INFO)'))
BEGIN
    CREATE NONCLUSTERED INDEX [IX_$(TABLE_CANVAS_INFO)_is_cached] ON [$(TABLE_CANVAS_INFO)] (is_cached);
END
GO

-- 10. 데이터베이스 소유자 및 생성된 테이블 목록 확인
SELECT name AS database_name, SUSER_SNAME(owner_sid) AS owner_name FROM sys.databases WHERE name = '$(DB_NAME)';
SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE';
GO
