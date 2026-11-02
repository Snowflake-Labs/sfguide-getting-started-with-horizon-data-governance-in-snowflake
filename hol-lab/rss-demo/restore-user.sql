-- =============================================================================
-- RSS DEMO: Detach the demo session policy from the operator user.
--
-- Run after hol-lab/02-04-Restricted-Session-Scope.sql whenever you want to
-- detach the user-level session policy that 02-04 attached. The optional
-- hol-lab/rss-demo/agent-role-proof.sql is read-only and needs no restore.
--
-- This script only detaches the user-level session policy. It does NOT touch
-- DEFAULT_ROLE or DEFAULT_WAREHOUSE; 02-04 does not change them.
--
-- LEAVES INTACT (for inspection):
--   AGENTIC_GOV_DB.GOVERNANCE.AGENT_DEMO_SESSION_POLICY
--   AGENTIC_GOV_DB.GOVERNANCE.AGENT_ANALYST_SCOPE
-- Final cleanup: hol-lab/99-Teardown.sql drops all demo objects.
--
-- Precondition: 02-04-Restricted-Session-Scope.sql must have run this session
-- (or an earlier one) for the operator to have a user-level session policy set.
-- =============================================================================

USE ROLE SECURITYADMIN;
SET operator_user = CURRENT_USER();

-- Detach user-level session policy; restores account-level session policy behavior.
-- Safe to run if already unset (UNSET is idempotent for this operator).
ALTER USER IDENTIFIER($operator_user) UNSET SESSION POLICY;

-- Confirm final state (dynamic read — no hardcoded username).
-- Expected: SESSION_POLICY value column is empty (no user-level policy set)
SHOW PARAMETERS LIKE 'SESSION_POLICY' IN USER;
