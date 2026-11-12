#!/usr/bin/env python3
"""SQL Server regression: preserve real legacy CHECKs when adding ORCID accounts.

Creates and removes only a uniquely named isolated test database. Requires the
administrator sqlcmd tool and MSSQL_SA_PASSWORD inside the selected container.
"""
import argparse
from pathlib import Path
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', default='agora-mssql')
    args = parser.parse_args()
    migrations = Path(__file__).resolve().parents[1] / 'migrations'
    name = 'irade_orcid_constraints_' + uuid.uuid4().hex[:12]
    command = ['docker', 'exec', '-i', args.container, '/bin/bash', '-lc',
               'export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"; exec /opt/mssql-tools18/bin/sqlcmd "$@"',
               'sqlcmd', '-S', 'localhost', '-U', 'sa', '-C', '-b', '-I']

    def sql(text, database='master'):
        result = subprocess.run(command + ['-d', database], input=text, text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError((result.stdout + result.stderr)[-2000:])

    def migrate(filename):
        sql((migrations / filename).read_text().replace('$(TABLE_USERS)', 'users'), name)

    def rejected(statement, numbers=(547,)):
        sql("SET XACT_ABORT OFF; BEGIN TRY\n" + statement +
            "\nTHROW 51000, 'An invalid account was accepted', 1; END TRY BEGIN CATCH\n"
            f"IF ERROR_NUMBER() NOT IN ({','.join(map(str, numbers))}) THROW; END CATCH;\n", name)

    created = False
    try:
        sql(f"IF DB_ID(N'{name}') IS NOT NULL THROW 51000,'Test database exists',1; CREATE DATABASE [{name}];\nGO\n")
        created = True
        sql("""CREATE TABLE users (
 user_id INT IDENTITY PRIMARY KEY, email NVARCHAR(255) NULL, password_hash NVARCHAR(255) NULL,
 oauth_provider NVARCHAR(50) NULL, oauth_id NVARCHAR(255) NULL,
 status NVARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
 CONSTRAINT CK_users_Auth CHECK(status='WITHDRAWN' OR password_hash IS NOT NULL OR (oauth_provider IS NOT NULL AND oauth_id IS NOT NULL)),
 CONSTRAINT CK_users_EmailRequired CHECK(status='WITHDRAWN' OR email IS NOT NULL)
);
CREATE UNIQUE INDEX UQ_Users_Email ON users(email) WHERE email IS NOT NULL;
GO
""", name)
        migrate('2026-11-13-irade-orcid.sql')
        orcid_insert = "INSERT INTO users(orcid,orcid_issuer) VALUES('0000-0002-1825-0097','https://orcid.org');"
        rejected(orcid_insert)  # Reproduce the production error before applying the fix.
        migrate('2026-11-13-orcid-account-constraints.sql')
        sql(orcid_insert, name)
        sql("INSERT INTO users(orcid,orcid_issuer) VALUES('0000-0002-1825-0097','https://sandbox.orcid.org');", name)
        sql("INSERT INTO users(email,password_hash) VALUES('password@example.invalid','fixture');", name)
        sql("INSERT INTO users(email,oauth_provider,oauth_id) VALUES('social@example.invalid','google','fixture');", name)
        rejected("INSERT INTO users DEFAULT VALUES;")
        rejected("INSERT INTO users(password_hash) VALUES('fixture');")
        rejected("INSERT INTO users(oauth_provider,oauth_id) VALUES('google','missing-email');")
        rejected("INSERT INTO users(orcid) VALUES('0000-0002-1825-0097');")
        rejected("INSERT INTO users(orcid,orcid_issuer) VALUES('0000-0002-1825-0097','https://attacker.invalid');")
        rejected(orcid_insert, (2601, 2627))
        sql("UPDATE users SET status='WITHDRAWN',orcid=NULL,orcid_issuer=NULL WHERE orcid_issuer='https://orcid.org';", name)
        sql(orcid_insert, name)  # Erased identities can register under a fresh user ID.
        migrate('2026-11-13-orcid-account-constraints.sql')
        # Exercise the legacy init upgrade blocks with an active ORCID account.
        initialization = (migrations.parent / 'init-mssql.sql').read_text()
        for first,last in [('-- Withdrawn users retain historical references','-- WebAuthn public credentials'),('-- Provider subjects are opaque','-- Irreversibly anonymize withdrawn accounts')]:
            block = initialization[initialization.index(first):initialization.index(last)].replace('$(TABLE_USERS)','users')
            sql(block,name)
        rejected("INSERT INTO users(password_hash) VALUES('still-missing-email');")
        rejected("INSERT INTO users DEFAULT VALUES;")
        sql("IF EXISTS(SELECT 1 FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID('dbo.users') AND (is_disabled=1 OR is_not_trusted=1)) THROW 51000,'Untrusted constraints',1;", name)
        print('PASS SQL Server: reproduced legacy rejection; ORCID-only registration, identity uniqueness, issuer isolation, erasure/rejoin, ordinary email/auth requirements and repeatable migration')
    finally:
        if created:
            sql(f'ALTER DATABASE [{name}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{name}];\nGO\n')


if __name__ == '__main__':
    main()
