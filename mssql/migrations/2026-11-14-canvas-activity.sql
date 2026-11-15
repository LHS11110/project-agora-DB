IF OBJECT_ID('dbo.user_canvas_activity','U') IS NULL
CREATE TABLE dbo.user_canvas_activity(
 user_id int NOT NULL REFERENCES dbo.users(user_id) ON DELETE CASCADE,
 canvas_id int NOT NULL,
 client_key varchar(160) NOT NULL,
 activity_date date NOT NULL,
 created_count bigint NOT NULL DEFAULT 0,
 updated_count bigint NOT NULL DEFAULT 0,
 deleted_count bigint NOT NULL DEFAULT 0,
 updated_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
 CONSTRAINT PK_user_canvas_activity PRIMARY KEY(user_id,activity_date,canvas_id,client_key),
 CONSTRAINT CK_user_canvas_activity_counts CHECK(created_count>=0 AND updated_count>=0 AND deleted_count>=0)
);
