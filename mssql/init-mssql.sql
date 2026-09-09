-- =======================================================
-- Agora MS SQL Server Database & Schema Initialization
-- sqlcmd 변수 사용: $(DB_NAME), $(DB_USER), $(DB_PASSWORD)
-- =======================================================

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
-- (이미 해당 DB 내부에 동일 이름의 비-dbo 사용자가 매핑되어 있는 경우 충돌 방지를 위해 정리 후 소유권 이전)
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

-- 6. Redis Server 등록 테이블 생성 (복합 기본키: redis_ip, redis_port)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'redis_server')
BEGIN
    CREATE TABLE redis_server (
        redis_ip    VARCHAR(45)   NOT NULL,          -- Redis IP 주소 (IPv4/IPv6 지원)
        redis_port  VARCHAR(10)   NOT NULL,          -- Redis 포트 번호
        created_at  DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_redis_server PRIMARY KEY CLUSTERED (redis_ip, redis_port)
    );
END
GO

-- 7. 캔버스 캐시 확인 테이블 생성
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'canvas_cache')
BEGIN
    CREATE TABLE canvas_cache (
        canvas_name NVARCHAR(255) NOT NULL,          -- 캔버스 이름 (기본키)
        redis_ip    VARCHAR(45)   NULL,              -- Redis IP 주소 (None 가능)
        redis_port  VARCHAR(10)   NULL,              -- Redis 포트 번호 (None 가능)
        is_cached   BIT           NOT NULL DEFAULT 0, -- 캐시 여부 (None 불가능, 0: False, 1: True)
        created_at  DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
        updated_at  DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_canvas_cache PRIMARY KEY CLUSTERED (canvas_name),
        -- 외래키 제약조건: redis_server의 (redis_ip, redis_port) 참조 (서버 삭제 시 NULL 처리)
        CONSTRAINT FK_canvas_cache_redis_server FOREIGN KEY (redis_ip, redis_port)
            REFERENCES redis_server (redis_ip, redis_port)
            ON DELETE SET NULL
            ON UPDATE CASCADE
    );
END
GO

-- 인덱스 생성 (조회 성능 향상)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_canvas_cache_is_cached' AND object_id = OBJECT_ID('canvas_cache'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_canvas_cache_is_cached ON canvas_cache (is_cached);
END
GO

-- 8. 샘플 데이터 입력 (테스트용)
-- (1) Redis 서버 등록
IF NOT EXISTS (SELECT 1 FROM redis_server WHERE redis_ip = '127.0.0.1' AND redis_port = '6379')
BEGIN
    INSERT INTO redis_server (redis_ip, redis_port)
    VALUES ('127.0.0.1', '6379');
END
GO

-- (2) 캔버스 캐시 정보 등록
IF NOT EXISTS (SELECT 1 FROM canvas_cache WHERE canvas_name = N'demo-canvas-01')
BEGIN
    INSERT INTO canvas_cache (canvas_name, redis_ip, redis_port, is_cached)
    VALUES 
        (N'demo-canvas-01', '127.0.0.1', '6379', 1),
        (N'demo-canvas-02', NULL, NULL, 0);
END
GO

-- 9. 데이터베이스 소유자 및 테이블 데이터 확인
SELECT name AS database_name, SUSER_SNAME(owner_sid) AS owner_name FROM sys.databases WHERE name = '$(DB_NAME)';
SELECT * FROM redis_server;
SELECT * FROM canvas_cache;
GO
