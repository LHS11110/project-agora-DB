-- Apply after deploying the read-only C++-collected activity API.
-- Visits and GitHub events are intentionally not converted to canvas edits.
IF OBJECT_ID('dbo.user_github_activity','U') IS NOT NULL DROP TABLE dbo.user_github_activity;
IF OBJECT_ID('dbo.user_activity','U') IS NOT NULL DROP TABLE dbo.user_activity;
