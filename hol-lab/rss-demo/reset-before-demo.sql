-- =============================================================================
-- RSS DEMO: Recovery utility — reset stale state before demo.
--
-- Run this ONLY when preflight finds stale state from a prior interrupted run.
-- This is NOT the normal demo path. After this script completes cleanly,
-- re-run preflight to confirm preconditions are met before proceeding with 02-04.
--
-- Usage:
--   snow sql -c <connection> -f hol-lab/rss-demo/reset-before-demo.sql
--
-- Stale state this script clears:
--   - User-level session policy attached from a prior interrupted 02-04 run
--   - AGENTIC_GOV_DB.GOVERNANCE.AGENT_DEMO_SESSION_POLICY
--   - AGENTIC_GOV_DB.GOVERNANCE.AGENT_ANALYST_SCOPE  (current scope)
--   - AGENTIC_GOV_DB.GOVERNANCE.AGENT_NOOP_SESSION_POLICY (discarded prior-iteration object)
--   - AGENTIC_GOV_DB.GOVERNANCE.AGENT_READ_ONLY_SCOPE (discarded prior-iteration object)
--
-- This redesign never changes DEFAULT_ROLE/DEFAULT_WAREHOUSE, so there is
-- nothing to restore there.
--
-- DOES NOT touch: lab database tables, policies applied by 01-02 / 02-03,
-- or any object outside the list above. Safe to run repeatedly (idempotent
-- drops + exception-safe UNSET).
-- =============================================================================

USE ROLE SECURITYADMIN;
SET operator_user = CURRENT_USER();

-- ============================================================================
-- 1.  UNSET USER-LEVEL SESSION POLICY (exception-safe)
--     Swallows "policy not attached" if a prior recovery or restore-user.sql
--     already unset it. UNSET must precede DROP SESSION POLICY (step 2) because
--     a policy currently attached to a user cannot be dropped.
-- ============================================================================

-- Exception-safe UNSET: swallows "policy not attached" error on repeated runs.
EXECUTE IMMEDIATE $$
DECLARE
  u STRING;
BEGIN
  u := CURRENT_USER();
  ALTER USER IDENTIFIER(:u) UNSET SESSION POLICY;
EXCEPTION WHEN OTHER THEN
  NULL;
END;
$$;

-- ============================================================================
-- 2.  DROP SESSION POLICIES AND RSS SCOPES
--     Drop order: session policies before scope (the policies reference the
--     scope; the referencing objects must be dropped first).
--     IF EXISTS on all drops — safe when objects were never created or were
--     already removed by a prior teardown or recovery run.
-- ============================================================================

DROP SESSION POLICY           IF EXISTS AGENTIC_GOV_DB.GOVERNANCE.AGENT_DEMO_SESSION_POLICY;
DROP SESSION POLICY           IF EXISTS AGENTIC_GOV_DB.GOVERNANCE.AGENT_NOOP_SESSION_POLICY;
DROP RESTRICTED SESSION SCOPE IF EXISTS AGENTIC_GOV_DB.GOVERNANCE.AGENT_ANALYST_SCOPE;

-- Discarded prior-iteration scope (safe no-op if it never existed on this account).
DROP RESTRICTED SESSION SCOPE IF EXISTS AGENTIC_GOV_DB.GOVERNANCE.AGENT_READ_ONLY_SCOPE;

-- ============================================================================
-- 3.  VERIFY CLEAN STATE
--     Confirm the policy is detached and no stale RSS objects remain. These
--     are the same checks preflight runs; a clean result here means preflight
--     should pass on the next run.
-- ============================================================================

-- RSS objects on this account.
-- Expected: 0 rows for AGENTIC_GOV_DB scopes after successful recovery.
SHOW RESTRICTED SESSION SCOPES IN ACCOUNT;

-- User-level session policy.
-- Expected: empty value column (no user-level policy attached).
-- If the value column is still non-empty, the UNSET in step 1 did not take
-- effect. Investigate the source of that policy before re-running preflight.
SHOW PARAMETERS LIKE 'SESSION_POLICY' IN USER;
