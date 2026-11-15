IF OBJECT_ID('dbo.user_activity', 'U') IS NULL
CREATE TABLE dbo.user_activity (
 user_id int NOT NULL REFERENCES dbo.users(user_id) ON DELETE CASCADE,
 activity_date date NOT NULL,
 canvas_id int NOT NULL DEFAULT 0,
 CONSTRAINT PK_user_activity PRIMARY KEY(user_id,activity_date,canvas_id),
 CONSTRAINT CK_user_activity_canvas CHECK(canvas_id>=0)
);
IF OBJECT_ID('dbo.user_github_activity', 'U') IS NULL
CREATE TABLE dbo.user_github_activity (
 user_id int NOT NULL PRIMARY KEY REFERENCES dbo.users(user_id) ON DELETE CASCADE,
 username varchar(39) NOT NULL,
 counts_json nvarchar(max) NOT NULL CHECK(ISJSON(counts_json)=1),
 updated_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
);
