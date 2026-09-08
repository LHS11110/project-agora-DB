-- 데이터베이스 생성 (존재하지 않을 경우)
IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = 'agora_db')
BEGIN
    CREATE DATABASE agora_db;
END
GO

USE agora_db;
GO

-- 캔버스 캐시 확인 테이블 생성
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'canvas_cache')
BEGIN
    CREATE TABLE canvas_cache (
        canvas_name NVARCHAR(255) NOT NULL,          -- 캔버스 이름 (기본키)
        redis_ip    VARCHAR(45)   NULL,              -- Redis IP 주소 (IPv4/IPv6 지원, None 가능)
        redis_port  VARCHAR(10)   NULL,              -- Redis 포트 번호 (None 가능)
        is_cached   BIT           NOT NULL DEFAULT 0, -- 캐시 여부 (None 불가능, 0: False, 1: True)
        created_at  DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
        updated_at  DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_canvas_cache PRIMARY KEY CLUSTERED (canvas_name)
    );
END
GO

-- 인덱스 생성 (조회 성능 향상)
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_canvas_cache_is_cached' AND object_id = OBJECT_ID('canvas_cache'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_canvas_cache_is_cached ON canvas_cache (is_cached);
END
GO

-- 샘플 데이터 입력 (테스트용)
INSERT INTO canvas_cache (canvas_name, redis_ip, redis_port, is_cached)
VALUES 
    (N'demo-canvas-01', '127.0.0.1', '6379', 1),
    (N'demo-canvas-02', NULL, NULL, 0);
GO

-- 데이터 확인
SELECT * FROM canvas_cache;
GO
