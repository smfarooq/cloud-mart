-- Phase 4/6: give the app identities access to Azure SQL. Bicep can't do this: it's T-SQL, not ARM.
--
-- Run against the "cloudmart" database while signed in as the server's Entra admin (you):
--   Portal > SQL database > Query editor (sign in with Entra ID), or
--   sqlcmd -S <server>.database.windows.net -d cloudmart -G -i deploy/sql/grant-managed-identities.sql
--
-- Replace the names with the deployment outputs apiIdentityName and functionsIdentityName.
-- "FROM EXTERNAL PROVIDER" resolves the name in Entra ID: a contained database user, no SQL login, no password.

CREATE USER [id-cloudmart-dev-api] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [id-cloudmart-dev-api];
ALTER ROLE db_datawriter ADD MEMBER [id-cloudmart-dev-api];
-- Only because the API creates its own schema on startup (EnsureCreated). In production, run migrations from the
-- pipeline and drop this: the app identity should not be able to change the schema.
ALTER ROLE db_ddladmin ADD MEMBER [id-cloudmart-dev-api];

CREATE USER [id-cloudmart-dev-func] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [id-cloudmart-dev-func];
ALTER ROLE db_datawriter ADD MEMBER [id-cloudmart-dev-func];

-- Check:
SELECT name, type_desc, authentication_type_desc FROM sys.database_principals WHERE name LIKE 'id-%';

-- ---------------------------------------------------------------------------------------------------------------
-- Phase 16: run this part against the "payments" database instead (switch database in the query editor, or
--   sqlcmd ... -d payments). Database per service: the Payments identity is a user here and nowhere else, and the
--   API and Functions identities are NOT users here: they reach payments only through the Payments API.
-- ---------------------------------------------------------------------------------------------------------------
-- CREATE USER [id-cloudmart-dev-pay] FROM EXTERNAL PROVIDER;
-- ALTER ROLE db_datareader ADD MEMBER [id-cloudmart-dev-pay];
-- ALTER ROLE db_datawriter ADD MEMBER [id-cloudmart-dev-pay];
-- ALTER ROLE db_ddladmin ADD MEMBER [id-cloudmart-dev-pay];  -- creates the ledger table on first start
-- -- Ledger tables are append-only for history: nobody can DELETE from dbo.Payments_Ledger, not even you.
-- SELECT * FROM dbo.Payments_Ledger ORDER BY ledger_transaction_id, ledger_sequence_number;
