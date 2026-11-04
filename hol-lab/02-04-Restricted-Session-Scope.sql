/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale
Part:         PART 2 - Agentic Governance
Section:      02-04 - Restricted Session Scope (RSS) — the session ceiling
Persona:      SECURITYADMIN (create + attach objects), AGOV_ANALYST
              (same operator user throughout — no role switch, no second login)
Story beat:   Agent Identity (02-03) governs what VALUES an agent may see in accessible data.
              Restricted Session Scope is a different, complementary control on a different axis:
              it is an RBAC-intersecting session CEILING that limits what PRIVILEGES and ROLES
              an agent-active session may use — irrespective of what the caller's RBAC would
              normally permit.

              The layered model:
                  effective agent authority = User RBAC ∩ RSS
              That intersection is then subject to Agent Identity value filtering.

              THIS IS A SECONDARY-ROLES DEMO — ONE Snowflake user, ONE primary role
              (AGOV_ANALYST), and USE SECONDARY ROLES ALL throughout. The operator's user
              is also granted AGOV_GOVERNOR directly (00-Setup section 0.1), so governor
              privileges — including UNMASK_ACCESS and AGENTIC_UNMASK_ACCESS — reach both
              human queries and agent execution contexts through secondary roles.
              Two beats, each shown via BOTH a direct SQL query and a Snowflake
              Intelligence (CoWork) chat conversation:

                BEAT 1 — Elevated baseline via secondary roles (no RSS yet).
                    Primary role: AGOV_ANALYST. USE SECONDARY ROLES ALL. AGOV_GOVERNOR
                    becomes a secondary role, carrying its UNMASK_ACCESS and
                    AGENTIC_UNMASK_ACCESS into the session. Direct SQL on EMAIL returns
                    real plaintext — governor's UNMASK_ACCESS fires through secondary
                    roles. A NEW CoWork conversation with the identical question also
                    returns real plaintext — governor's AGENTIC_UNMASK_ACCESS clears the
                    agent path too. Both paths see the same data. The analyst's own
                    grants would not have allowed plaintext; the secondary governor role
                    is what elevates access.

                BEAT 2 — RSS transparently strips the governor; the human is untouched.
                    Without changing the primary role or the SECONDARY ROLES ALL setting,
                    SECURITYADMIN attaches an RSS session policy whose allowed_roles list
                    contains only AGOV_ANALYST. Per the documented role-scope semantics,
                    allowed_roles constrains both primary and secondary roles: the
                    primary must match exactly, and secondary roles are limited to the
                    allowed roles plus the roles they inherit. AGOV_GOVERNOR is not
                    inherited by AGOV_ANALYST, so it is excluded from secondaries in the
                    agent context.

                    Result: a direct SQL query in the SAME session STILL shows real
                    plaintext — RSS is inert when IS_AGENT_ACTIVATED = FALSE, so the
                    human's secondary roles are unchanged. But a NEW CoWork conversation
                    with the IDENTICAL question now returns
                    ***EXCLUDED-FROM-AGENTIC-USE*** — the agent's context no longer has
                    AGOV_GOVERNOR as a secondary role, so both UNMASK_ACCESS and
                    AGENTIC_UNMASK_ACCESS are gone, and the masking policy's sensitive-
                    tier exclusion fires. The agent still executes — no refusal, no
                    error — it just sees redacted data. The human caller's grants are
                    unchanged; only the agent's ceiling narrowed.

              The payoff: same primary role, same SECONDARY ROLES ALL, same query,
              same human result — the ONLY thing that changed is what the agent sees.
              RSS did not break anything and did not force a role switch; it
              transparently reduced the agent's secondary-role surface.

              Crucially:
              • RSS does NOT grant new privileges — it can only narrow existing ones.
              • The session policy's AGENT_RESTRICTED_SESSION_SCOPE applies only
                when IS_AGENT_ACTIVATED = TRUE. It does not restrict human queries.
                Other settings in the attached session policy still matter for humans.
              • A user-level session policy (set here) takes precedence over an
                account-level session policy; they do NOT merge.
              • allowed_roles constrains both primary and secondary roles. Secondary
                roles are limited to allowed roles plus roles they inherit. Excluding a
                 secondary role removes the privileges it carried.

              IMPORTANT — OPERATOR IMPACT:
              This script attaches a USER-LEVEL session policy to CURRENT_USER().
              That TEMPORARILY OVERRIDES any account-level session policy for the
              operator. It does NOT merge with the account policy. The operator's
              human SQL is not restricted by the agent RSS property, but other
              account session-policy settings can be displaced by this attachment.
              Section 02-04.6 detaches only the demo user-level policy in a human
              worksheet, restoring account-level behavior. Start a fresh CoCo
              chat and Snowflake session afterward. Teardown repeats the guarded
              cleanup if needed. This script never changes DEFAULT_ROLE or
              DEFAULT_WAREHOUSE, so there is nothing else to restore.

              PRECONDITION: The operator (CURRENT_USER) must NOT already have a
              user-level session policy attached. The preflight check below will
              show the current state; if one exists, this script must not proceed.

              LIVE-DEMO NOTE: the SQL in this script is written so a presenter can
              run every step in a worksheet as a rehearsal, AND so the same steps can
              be narrated live with the CoWork portions performed by hand in
              Snowsight. Every UI-only step is called out in a clearly marked
              "PRESENTER:" comment block — start a NEW CoWork conversation and ask the
              exact question shown.

Diagram:      images/agent-identity-three-contexts.svg (Agent Identity clause);
              this script adds the RSS ceiling on top of that same clause.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
***************************************************************************************************/

USE ROLE SECURITYADMIN;
USE WAREHOUSE AGOV_WH;
USE DATABASE AGENTIC_GOV_DB;
USE SECONDARY ROLES NONE;

-- ============================================================================
-- 02-04.0  PRECONDITION: operator identity + pre-existing policy guard
-- ============================================================================
SELECT CURRENT_USER() AS operator_user;
SET operator_user = CURRENT_USER();

-- Stop before changing anything if a user session policy is already attached.
-- Network/authentication policies are different policy kinds and are not removed.
EXECUTE IMMEDIATE $$
DECLARE
    existing_policy_count INTEGER;
    existing_policy EXCEPTION (-20001, 'User already has a session policy; do not overwrite it.');
BEGIN
    SELECT COUNT(*) INTO :existing_policy_count
    FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => CURRENT_USER(), REF_ENTITY_DOMAIN => 'USER'))
    WHERE POLICY_KIND = 'SESSION_POLICY';
    IF (existing_policy_count > 0) THEN
        RAISE existing_policy;
    END IF;
END;
$$;

-- ============================================================================
-- 02-04.1  BEAT 1 — ELEVATED BASELINE VIA SECONDARY ROLES (no RSS yet)
--      Primary role: AGOV_ANALYST. USE SECONDARY ROLES ALL brings
--      AGOV_GOVERNOR into the session as a secondary role. Governor carries
--      UNMASK_ACCESS (database role, 01-02) and AGENTIC_UNMASK_ACCESS
--      (account role, 00-Setup), so both human queries and agent execution
--      contexts see real plaintext — even though the analyst's own grants
--      would not allow it. This is the baseline that RSS will narrow.
--
--      GROUP BY EMAIL is used for direct SQL because AGG_POLICY
--      (01-02-Data-Governance.sql) requires aggregation with
--      MIN_GROUP_SIZE => 100 for non-exempt roles. With governor as a
--      secondary role, AGG_POLICY's NO_AGGREGATION_CONSTRAINT() fires and
--      the GROUP BY returns multiple distinct plaintext rows.
-- ============================================================================
USE ROLE AGOV_ANALYST;
USE WAREHOUSE AGOV_WH;
USE SECONDARY ROLES ALL;

SELECT
    'beat1: analyst + secondary ALL, direct SQL, no RSS' AS test_case,
    CURRENT_ROLE()                                          AS primary_role,
    IS_ROLE_IN_SESSION('AGOV_GOVERNOR')                     AS governor_secondary,
    SYS_CONTEXT('SNOWFLAKE$CURRENT','IS_AGENT_ACTIVATED')    AS is_agent_activated;
-- Expected: primary_role = AGOV_ANALYST, governor_secondary = TRUE,
-- is_agent_activated = FALSE.

SELECT
    EMAIL,
    COUNT(*) AS visible_rows
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS
GROUP BY EMAIL
ORDER BY visible_rows DESC
LIMIT 5;
-- Expected: MANY rows, each a real, distinct plaintext email — governor's
-- UNMASK_ACCESS reaches through secondary roles, and AGG_POLICY's
-- NO_AGGREGATION_CONSTRAINT() for AGOV_GOVERNOR removes the group-size floor.

-- Headless proxy for the CoWork step below (useful for scripted rehearsal).
WITH r AS (
    SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
        'AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT',
        $${"messages":[{"role":"user","content":[{"type":"text","text":"List 5 customers with their full name and email address."}]}]}$$,
        TRUE
    ) AS raw
),
parsed AS (
    SELECT
        MAX(CASE WHEN f.value:type::STRING = 'text'
             THEN TRIM(f.value:text::STRING) END)                              AS agent_answer,
        LISTAGG(CASE WHEN f.value:type::STRING = 'tool_result'
                     THEN TO_JSON(f.value:tool_result:content) END, '\n')     AS tool_outputs
    FROM r, LATERAL FLATTEN(input => PARSE_JSON(r.raw):content, OUTER => TRUE) f
)
SELECT
    'beat1: analyst + secondary ALL, agent (headless proxy), no RSS' AS scenario,
    agent_answer,
    tool_outputs
FROM parsed;
-- Expected: tool_outputs shows real, varied plaintext FULL_NAME and EMAIL
-- values. AGOV_GOVERNOR as a secondary role carries both UNMASK_ACCESS and
-- AGENTIC_UNMASK_ACCESS into the agent context, clearing both checks in the
-- masking policy's agent branch. Same data as the direct SQL query.

-- ----------------------------------------------------------------------------
-- PRESENTER: in Snowsight, confirm the role dropdown shows AGOV_ANALYST and
-- secondary roles are set to ALL, then open a NEW CoWork (Snowflake
-- Intelligence) conversation and ask:
--     "List 5 customers with their full name and email address."
-- Expected: real plaintext names/emails — governor reaches the agent through
-- secondary roles. Point out that the PRIMARY role is still the non-privileged
-- analyst; it is the secondary governor that elevates access.
-- ----------------------------------------------------------------------------

-- ============================================================================
-- 02-04.2  RESTRICTED SESSION SCOPE OBJECT + SESSION POLICY
--      Define the named scope using CREATE OR ALTER RESTRICTED SESSION SCOPE.
--
--      role_scopes / allowed_roles: an ALLOW-LIST containing ONLY AGOV_ANALYST.
--        Per the documented semantics, allowed_roles constrains both primary and
--        secondary roles. Secondary roles are limited to the allowed roles plus
--        the roles they inherit. AGOV_GOVERNOR is not inherited by AGOV_ANALYST,
--        so it is excluded from the agent's secondaries — and with it, the
--        UNMASK_ACCESS and AGENTIC_UNMASK_ACCESS privileges it carried.
--      allow_role_switching: true — the agent can switch among allowed roles
--        within the ceiling, but cannot activate an excluded role.
--
--      This scope is ONLY active when IS_AGENT_ACTIVATED = TRUE in the session.
--      When IS_AGENT_ACTIVATED = FALSE (any direct human query), the scope has
--      no effect — proven in Beat 2 immediately below.
--
--      SECURITYADMIN creates and owns the scope and the session policy. It must
--      never appear in allowed_roles: it stays outside the ceiling as the
--      break-glass role for the human-run cleanup in 02-04.6.
-- ============================================================================
USE ROLE SECURITYADMIN;
USE WAREHOUSE AGOV_WH;
USE DATABASE AGENTIC_GOV_DB;

-- SECURITYADMIN grants itself the schema-level create privileges (MANAGE GRANTS).
-- verified in rehearsal 2026-11-02
GRANT CREATE SESSION POLICY           ON SCHEMA AGENTIC_GOV_DB.GOVERNANCE TO ROLE SECURITYADMIN;
GRANT CREATE RESTRICTED SESSION SCOPE ON SCHEMA AGENTIC_GOV_DB.GOVERNANCE TO ROLE SECURITYADMIN;

CREATE OR ALTER RESTRICTED SESSION SCOPE AGENTIC_GOV_DB.GOVERNANCE.AGENT_ANALYST_SCOPE
AS $$
role_scopes:
  allowed_roles: [AGOV_ANALYST]
  allow_role_switching: true
$$;

CREATE OR REPLACE SESSION POLICY AGENTIC_GOV_DB.GOVERNANCE.AGENT_DEMO_SESSION_POLICY
    AGENT_RESTRICTED_SESSION_SCOPE =
        'AGENTIC_GOV_DB.GOVERNANCE.AGENT_ANALYST_SCOPE'
    COMMENT = 'Demo: allowed_roles = [AGOV_ANALYST] strips AGOV_GOVERNOR from agent secondaries transparently.';

-- ============================================================================
-- 02-04.3  BEAT 2 — RSS TRANSPARENTLY STRIPS THE GOVERNOR; HUMAN IS UNTOUCHED
--      Attach the session policy. The precondition requires no existing
--      attachment. Do not remove an unrelated user policy to make this run.
--
--      After attachment, switch back to analyst primary + SECONDARY ROLES ALL
--      — the exact same role setup as Beat 1. The ONLY change is the attached
--      session policy. Direct SQL still shows plaintext (RSS inert for humans);
--      the agent now sees redacted values (governor excluded from secondaries).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- OPERATOR WARNING: read before attaching the policy below.
--   This RSS is admin-managed and attached to YOUR user. It also constrains
--   Cortex Code (CoCo) Desktop and any other agent acting on Snowflake as you.
--   - Agent sessions must use AGOV_ANALYST as the primary role.
--   - Elevated secondary roles (AGOV_GOVERNOR, SECURITYADMIN, ACCOUNTADMIN) are unavailable
--     to the agent. Your own human SQL in a worksheet keeps all your roles.
--   - Analyst primary lets the agent do analyst work only. It cannot
--     administer policies, scopes, grants or users.
--   - Cleanup (UNSET the user session policy) must be run MANUALLY in a human
--     Snowsight worksheet as SECURITYADMIN. Do not ask the restricted agent.
-- ----------------------------------------------------------------------------
USE ROLE SECURITYADMIN;
ALTER USER IDENTIFIER($operator_user)
    SET SESSION POLICY AGENTIC_GOV_DB.GOVERNANCE.AGENT_DEMO_SESSION_POLICY;

USE ROLE AGOV_ANALYST;
USE WAREHOUSE AGOV_WH;
USE SECONDARY ROLES ALL;

SELECT
    'beat2: analyst + secondary ALL, direct SQL, RSS attached' AS test_case,
    CURRENT_ROLE()                                          AS primary_role,
    IS_ROLE_IN_SESSION('AGOV_GOVERNOR')                     AS governor_secondary,
    SYS_CONTEXT('SNOWFLAKE$CURRENT','IS_AGENT_ACTIVATED')    AS is_agent_activated;
-- Expected: primary_role = AGOV_ANALYST, governor_secondary = TRUE (human
-- session unchanged), is_agent_activated = FALSE.

SELECT
    EMAIL,
    COUNT(*) AS visible_rows
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS
GROUP BY EMAIL
ORDER BY visible_rows DESC
LIMIT 5;
-- Expected: IDENTICAL to Beat 1 — many rows, real plaintext emails. RSS is
-- inert when IS_AGENT_ACTIVATED = FALSE. The human still has governor through
-- secondary roles. This is the key contrast: same role, same secondaries,
-- same query, same result — the human session was never touched.

WITH r AS (
    SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
        'AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT',
        $${"messages":[{"role":"user","content":[{"type":"text","text":"List 5 customers with their full name and email address."}]}]}$$,
        TRUE
    ) AS raw
),
parsed AS (
    SELECT
        MAX(CASE WHEN f.value:type::STRING = 'text'
             THEN TRIM(f.value:text::STRING) END)                              AS agent_answer,
        LISTAGG(CASE WHEN f.value:type::STRING = 'tool_result'
                     THEN TO_JSON(f.value:tool_result:content) END, '\n')     AS tool_outputs
    FROM r, LATERAL FLATTEN(input => PARSE_JSON(r.raw):content, OUTER => TRUE) f
)
SELECT
    'beat2: analyst + secondary ALL, agent (headless proxy), RSS attached' AS scenario,
    agent_answer,
    tool_outputs
FROM parsed;
-- Expected: tool_outputs shows every EMAIL as '***EXCLUDED-FROM-AGENTIC-USE***'
-- and every FULL_NAME as '***EXCLUDED-FROM-AGENTIC-USE***'. The agent still
-- executes — no refusal, no error — but governor was excluded from the agent's
-- secondaries by the RSS allow-list, so UNMASK_ACCESS and AGENTIC_UNMASK_ACCESS
-- are gone. The masking policy's agent branch hits the sensitive-tier check and
-- returns the exclusion sentinel. Compare directly to Beat 1: SAME role, SAME
-- secondary setting, SAME query — different agent result. RSS transparently
-- narrowed what the agent could see without touching the human's access.

SELECT
    'beat2: outer session after agent call' AS test_case,
    IS_ROLE_IN_SESSION('AGOV_GOVERNOR')     AS governor_still_secondary;
-- Expected: TRUE — unchanged. RSS narrowed the agent's own execution context,
-- not the calling session's roles. The human caller still has governor through
-- secondary roles; only the agent's ceiling was lowered.

-- ----------------------------------------------------------------------------
-- PRESENTER: confirm the role dropdown still shows AGOV_ANALYST with secondary
-- roles ALL. Open a NEW CoWork conversation (required: start fresh after the
-- policy attachment) and ask the SAME question:
--     "List 5 customers with their full name and email address."
-- Expected: every email shown as ***EXCLUDED-FROM-AGENTIC-USE***. Point back
-- to the direct SQL query in the SAME worksheet session — still plaintext.
-- The punchline: same role, same secondary roles, same query. RSS did not
-- force a role switch or break the agent; it transparently removed the
-- governor's privileges from the agent's session ceiling. The human caller's
-- access is completely unchanged.
-- ----------------------------------------------------------------------------

-- ============================================================================
-- 02-04.4  CONFIGURATION VERIFICATION
-- ============================================================================
USE ROLE SECURITYADMIN;

-- RSS objects registered in this schema
SHOW RESTRICTED SESSION SCOPES IN SCHEMA AGENTIC_GOV_DB.GOVERNANCE;
-- Check: the scope body in 02-04.2 lists allowed_roles: [AGOV_ANALYST] only.
-- SECURITYADMIN (and ACCOUNTADMIN) must never be added to allowed_roles, so the
-- human cleanup role stays outside the agent ceiling.

-- Inspect the YAML ceiling — allow-list of AGOV_ANALYST only
DESCRIBE RESTRICTED SESSION SCOPE AGENTIC_GOV_DB.GOVERNANCE.AGENT_ANALYST_SCOPE;

-- Session policy properties (shows AGENT_RESTRICTED_SESSION_SCOPE reference)
DESCRIBE SESSION POLICY AGENTIC_GOV_DB.GOVERNANCE.AGENT_DEMO_SESSION_POLICY;

-- Confirm the policy is attached to the operator.
SELECT POLICY_DB, POLICY_SCHEMA, POLICY_NAME, POLICY_KIND, POLICY_STATUS
FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.POLICY_REFERENCES(
    REF_ENTITY_NAME => CURRENT_USER(), REF_ENTITY_DOMAIN => 'USER'))
WHERE POLICY_KIND = 'SESSION_POLICY';

-- Attachment and activation are different. This is the outer human session;
-- an empty active-scopes array here does not describe the agent's child session.
SELECT SYS_CONTEXT('SNOWFLAKE$SESSION', 'ACTIVE_RESTRICTED_SESSION_SCOPES') AS active_scopes,
       SYS_CONTEXT('SNOWFLAKE$CURRENT', 'IS_AGENT_ACTIVATED') AS agent_active;

-- ============================================================================
-- 02-04.5  OUTCOME MATRIX
-- ============================================================================
/*
  Beat | Primary role  | Secondary roles | Session policy   | Direct SQL          | Agent / CoWork result
  -----|---------------|-----------------|-------------------|---------------------|-------------------------------
  1    | AGOV_ANALYST  | ALL (governor   | (none)            | real plaintext       | real plaintext
       |               | is secondary)   |                   | (governor secondary) | (governor secondary)
  2    | AGOV_ANALYST  | ALL (governor   | AGENT_DEMO_...    | real plaintext       | ***EXCLUDED-FROM-AGENTIC-USE***
       |               | is secondary)   | (RSS attached)    | (human unchanged)    | (governor stripped from agent)

  The setup never changes the primary role. AGOV_ANALYST is primary throughout;
  AGOV_GOVERNOR reaches the session as a secondary role via USE SECONDARY ROLES
  ALL. Governor carries UNMASK_ACCESS and AGENTIC_UNMASK_ACCESS, which clear
  both the human masking path and the agent's paired-clearance checks.

  Beat 1 establishes that secondary roles elevate both human and agent access
  equally — same query, same plaintext, same role. Beat 2 attaches the RSS
  session policy whose allowed_roles list names only AGOV_ANALYST. Per the
  documented semantics, allowed_roles constrains secondary roles to the allowed
  roles plus their inheritees. AGOV_GOVERNOR is not inherited by AGOV_ANALYST,
  so it is excluded from the agent's secondary roles — and with it, the
  UNMASK_ACCESS and AGENTIC_UNMASK_ACCESS privileges it carried. The human
  session is unaffected because AGENT_RESTRICTED_SESSION_SCOPE applies only
  when IS_AGENT_ACTIVATED = TRUE.

  The result: the agent still executes (no refusal), but sees
  ***EXCLUDED-FROM-AGENTIC-USE*** where it previously saw plaintext. The human
  still sees plaintext from the same worksheet, same role, same secondary
  setting. RSS transparently reduced what the agent could access without
  touching the human's grants, forcing a role switch, or breaking the agent.

  GROUP BY EMAIL is used for direct SQL because AGG_POLICY
  (01-02-Data-Governance.sql) requires aggregation with MIN_GROUP_SIZE => 100.
  With governor as a secondary role (human session), NO_AGGREGATION_CONSTRAINT()
  fires and the query returns multiple distinct plaintext rows. After RSS strips
  governor from the agent's secondaries, the agent's Cortex Analyst tool handles
  aggregation compliance through the semantic view's own query generation.
*/

-- ============================================================================
-- 02-04.6  HUMAN-RUN CLEANUP: detach the demo session policy
--      Run MANUALLY in a human Snowsight worksheet as SECURITYADMIN with
--      warehouse AGOV_WH. Do not ask the restricted agent to run this.
--
--      Only the user-level attachment is removed. The RSS object and the
--      session policy are retained for re-runs and are dropped by teardown.
--
--      The block detaches only when the single session policy on this user
--      is exactly AGENTIC_GOV_DB.GOVERNANCE.AGENT_DEMO_SESSION_POLICY. No
--      session policy is a no-op. Any other session policy raises -20002
--      and is left untouched.
-- ============================================================================
USE ROLE SECURITYADMIN;
USE WAREHOUSE AGOV_WH;

EXECUTE IMMEDIATE $$
DECLARE
    u STRING;
    total_count INTEGER;
    exact_count INTEGER;
    unexpected_policy EXCEPTION (-20002, 'Unexpected user session policy found; it was left untouched.');
BEGIN
    u := CURRENT_USER();
    SELECT COUNT(*),
           COUNT_IF(POLICY_DB = 'AGENTIC_GOV_DB'
                    AND POLICY_SCHEMA = 'GOVERNANCE'
                    AND POLICY_NAME = 'AGENT_DEMO_SESSION_POLICY')
    INTO :total_count, :exact_count
    FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => CURRENT_USER(), REF_ENTITY_DOMAIN => 'USER'))
    WHERE POLICY_KIND = 'SESSION_POLICY';
    IF (total_count = 0) THEN
        RETURN 'No user session policy attached. Nothing to detach.';
    ELSEIF (total_count = 1 AND exact_count = 1) THEN
        ALTER USER IDENTIFIER(:u) UNSET SESSION POLICY;
        RETURN 'Detached AGENTIC_GOV_DB.GOVERNANCE.AGENT_DEMO_SESSION_POLICY.';
    ELSE
        RAISE unexpected_policy;
    END IF;
END;
$$;

-- Verify: expect zero rows.
SELECT POLICY_DB, POLICY_SCHEMA, POLICY_NAME, POLICY_KIND, POLICY_STATUS
FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.POLICY_REFERENCES(
    REF_ENTITY_NAME => CURRENT_USER(), REF_ENTITY_DOMAIN => 'USER'))
WHERE POLICY_KIND = 'SESSION_POLICY';

-- ----------------------------------------------------------------------------
-- PRESENTER: after the detach, start a FRESH CoCo chat and a fresh Snowflake
-- session using your usual connection and role. An admin-managed RSS cannot
-- be relaxed inside a session that already started under it, so existing
-- agent sessions keep the narrowed ceiling until they are replaced.
--
-- REQUIRED before Part 3 (03-01) and Part 4 (04-01, 04-02): this cleanup and the
-- fresh session. Do not continue the lab from the session that ran 02-04.
-- ----------------------------------------------------------------------------
