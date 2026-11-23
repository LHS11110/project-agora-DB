IF OBJECT_ID(N'dbo.agent_terms', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.agent_terms (
        version VARCHAR(40) NOT NULL CONSTRAINT PK_agent_terms PRIMARY KEY,
        body NVARCHAR(MAX) NOT NULL,
        published_at DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    );
END;
IF OBJECT_ID(N'dbo.agent_term_decisions', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.agent_term_decisions (
        user_id INT NOT NULL REFERENCES dbo.[$(TABLE_USERS)](user_id),
        terms_version VARCHAR(40) NOT NULL REFERENCES dbo.agent_terms(version),
        accepted BIT NOT NULL,
        decision_at DATETIME2 NOT NULL,
        CONSTRAINT PK_agent_term_decisions PRIMARY KEY (user_id, terms_version)
    );
END;
IF NOT EXISTS (SELECT 1 FROM dbo.agent_terms WHERE version='agent-local-v2')
BEGIN
    INSERT INTO dbo.agent_terms(version, body) VALUES ('agent-local-v2',
        N'AI 에이전트는 선택 기능입니다. 캔버스에 접근 권한이 있는 로그인 이용자는 이 약관에 동의한 뒤 사용할 수 있습니다. 에이전트 설정에서 동의를 철회해도 기본 캔버스 기능은 계속 이용할 수 있습니다.' + NCHAR(10) +
        N'요청은 Agora 서버에서 실행되는 로컬 모델이 처리합니다. 질문에 답하거나 메모를 만들 수 있고, 캔버스를 변경하는 작업에는 이용자의 기존 권한이 적용됩니다.' + NCHAR(10) +
        N'이용자는 사용할 권한이 있는 내용만 입력해야 하며, 다른 사람의 개인정보나 기밀정보를 동의 없이 입력하거나 공유해서는 안 됩니다. 불법 행위, 괴롭힘 또는 다른 참여자의 권리를 침해하는 데 에이전트를 사용해서는 안 됩니다.' + NCHAR(10) +
        N'AI가 생성한 답변과 메모에는 오류가 있을 수 있습니다. 사용하거나 공유하기 전에 내용을 확인해주세요.');
END;
GO
