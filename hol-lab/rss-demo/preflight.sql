-- =============================================================================
-- CAPABILITY PREFLIGHT: Restricted Session Scope (RSS)
-- Run BEFORE 02-04-Restricted-Session-Scope.sql to confirm the target account
-- supports Restricted Session Scope and meets preconditions.
--
-- Usage:
--   snow sql -c <connection> -f hol-lab/rss-demo/preflight.sql
--
-- All queries are read-only. No objects are created or modified.
-- PRECONDITION: Current operator (CURRENT_USER) must NOT have a user-level
-- session policy attached. If one exists, 02-04 must not proceed.
--
-- NOTE: 02-04 does NOT change the operator's DEFAULT_ROLE or DEFAULT_WAREHOUSE.
-- 02-04 is a secondary-roles demo: ONE Snowflake user keeps AGOV_ANALYST as
-- its PRIMARY role with USE SECONDARY ROLES ALL throughout - no role switch.
-- AGOV_GOVERNOR reaches the session as a secondary role, and DATA_AGENT_RUN
-- executes inside that calling session, so the agent sees the same roles
-- until the RSS session policy narrows its secondaries.
-- =============================================================================

USE ROLE SECURITYADMIN;
USE SECONDARY ROLES NONE;

-- ---------------------------------------------------------------------------
-- P.1  Account identity and version
-- ---------------------------------------------------------------------------
SELECT
    CURRENT_ACCOUNT()              AS account_locator,
    CURRENT_REGION()                AS region,
    CURRENT_VERSION()               AS snowflake_version,
    CURRENT_USER()                  AS operator_user,
    CURRENT_ROLE()                  AS operator_role;
-- Expected: version >= 8.x, confirms account and operator

-- ---------------------------------------------------------------------------
-- P.2  IS_AGENT_ACTIVATED in a normal (non-agent) session
-- ---------------------------------------------------------------------------
SELECT
    SYS_CONTEXT('SNOWFLAKE$CURRENT','IS_AGENT_ACTIVATED') AS is_agent_activated;
-- Expected: FALSE  (no agent running in this human session)

-- ---------------------------------------------------------------------------
-- P.3  Session policy feature surface
--      If AGENT_RESTRICTED_SESSION_SCOPE appears in the property list of
--      a session policy, RSS is available on this account.
-- ---------------------------------------------------------------------------
SHOW SESSION POLICIES IN ACCOUNT;
-- Inspect results; the AGENT_RESTRICTED_SESSION_SCOPE column/property
-- indicates RSS availability.

-- ---------------------------------------------------------------------------
-- P.4  Operator has both AGOV_ANALYST and AGOV_GOVERNOR granted DIRECTLY
--      02-04 uses AGOV_ANALYST as the primary role and relies on
--      USE SECONDARY ROLES ALL to bring AGOV_GOVERNOR in as a secondary role.
--      Both must be direct user grants: AGOV_ANALYST does not inherit
--      AGOV_GOVERNOR. (00-Setup.sql grants every persona directly.)
-- ---------------------------------------------------------------------------
SET operator_user = CURRENT_USER();
SHOW GRANTS TO USER IDENTIFIER($operator_user);
SELECT "role" AS granted_role
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "role" IN ('AGOV_ANALYST', 'AGOV_GOVERNOR');
-- Expected: both AGOV_ANALYST and AGOV_GOVERNOR rows present (direct grants
-- from 00-Setup.sql). If either is missing, re-run 00-Setup.sql first.

-- ---------------------------------------------------------------------------
-- P.5  RSS objects currently configured on this account
-- ---------------------------------------------------------------------------
SHOW RESTRICTED SESSION SCOPES IN ACCOUNT;
-- Expected before 02-04 runs: 0 rows for AGENTIC_GOV_DB objects
-- Expected after  02-04 runs: 1 row - AGENTIC_GOV_DB.GOVERNANCE.AGENT_ANALYST_SCOPE
-- Any other AGENTIC_GOV_DB scope is stale state from a prior iteration; clear it
-- with hol-lab/rss-demo/reset-before-demo.sql.

-- ---------------------------------------------------------------------------
-- P.6  PRECONDITION CHECK: no user-level session policy on CURRENT_USER
--      If the 'value' column is non-empty, STOP. Do not run 02-04.
--      02-04 attaches a user-level policy which OVERRIDES (not merges with)
--      any existing user-level policy. Teardown UNSETs it, which only safely
--      restores account-level behavior if no user-level policy existed before.
-- ---------------------------------------------------------------------------
SHOW PARAMETERS LIKE 'SESSION_POLICY' IN USER;
-- Expected: empty / no user-level session policy set
-- If non-empty: DO NOT proceed with 02-04.

-- ---------------------------------------------------------------------------
-- P.7  Lab database existence check (must have run 00-Setup.sql first)
-- ---------------------------------------------------------------------------
SHOW DATABASES LIKE 'AGENTIC_GOV_DB';
-- Expected: 1 row (database exists and is accessible)
