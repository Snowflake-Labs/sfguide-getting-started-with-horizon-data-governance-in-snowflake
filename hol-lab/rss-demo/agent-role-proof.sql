-- =============================================================================
-- AGENT ROLE PROOF (OPTIONAL): fresh-session rehearsal of the two 02-04 beats.
-- Run in a NEW `snow sql -f` session to confirm the SQL halves of
-- 02-04-Restricted-Session-Scope.sql produce the expected human and agent
-- results outside the session that ran 02-04.
--
-- Same design as 02-04: ONE user, ONE primary role (AGOV_ANALYST), and
-- USE SECONDARY ROLES ALL throughout. AGOV_GOVERNOR reaches the session as a
-- secondary role and carries UNMASK_ACCESS and AGENTIC_UNMASK_ACCESS.
--
-- READ-ONLY: this script creates, attaches, and detaches nothing. Use the
-- canonical 02-04 steps to create the scope/policy and attach it. Run this
-- script twice:
--   BASELINE   before 02-04.3 attaches AGENT_DEMO_SESSION_POLICY
--              -> human plaintext, agent plaintext
--   TREATMENT  after 02-04.3 has attached it (new session)
--              -> human plaintext, agent ***EXCLUDED-FROM-AGENTIC-USE***
-- Section R.0 detects which phase applies, and each result row carries the
-- expected outcome for that phase.
--
-- This does NOT reproduce the CoWork halves of each beat; walk those manually
-- in Snowsight (see the PRESENTER comments in 02-04). Classify agent outcomes
-- strictly from tool_outputs, never from agent_answer prose or CLI exit status.
--
-- Usage:
--   snow sql -c <connection> -f hol-lab/rss-demo/agent-role-proof.sql
-- =============================================================================

-- ---------------------------------------------------------------------------
-- R.0  PHASE DETECTION (read-only)
--      Policy attachment is read from policy references, not from active-scope
--      introspection in this human session.
-- ---------------------------------------------------------------------------
USE ROLE SECURITYADMIN;
USE WAREHOUSE AGOV_WH;
USE DATABASE AGENTIC_GOV_DB;

SET rss_attached = (
    SELECT COUNT(*) > 0
    FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => CURRENT_USER(), REF_ENTITY_DOMAIN => 'USER'))
    WHERE POLICY_KIND = 'SESSION_POLICY'
      AND POLICY_DB = 'AGENTIC_GOV_DB'
      AND POLICY_SCHEMA = 'GOVERNANCE'
      AND POLICY_NAME = 'AGENT_DEMO_SESSION_POLICY'
);

SELECT POLICY_DB, POLICY_SCHEMA, POLICY_NAME, POLICY_KIND, POLICY_STATUS
FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.POLICY_REFERENCES(
    REF_ENTITY_NAME => CURRENT_USER(), REF_ENTITY_DOMAIN => 'USER'))
WHERE POLICY_KIND = 'SESSION_POLICY';

SELECT
    CURRENT_USER()                               AS operator_user,
    $rss_attached                                AS rss_attached,
    IFF($rss_attached, 'TREATMENT', 'BASELINE')  AS phase;
-- Expected: BASELINE before 02-04.3, TREATMENT after it. If a session policy
-- other than AGENT_DEMO_SESSION_POLICY appears above, stop: 02-04 must not run.

SHOW RESTRICTED SESSION SCOPES LIKE 'AGENT_ANALYST_SCOPE' IN SCHEMA AGENTIC_GOV_DB.GOVERNANCE;
-- Expected: 1 row once 02-04.2 has run; 0 rows before that.

-- ---------------------------------------------------------------------------
-- R.1  HUMAN SESSION: analyst primary, governor secondary
-- ---------------------------------------------------------------------------
USE ROLE AGOV_ANALYST;
USE WAREHOUSE AGOV_WH;
USE SECONDARY ROLES ALL;

SELECT
    'R.1: fresh-session context' AS scenario,
    IFF($rss_attached, 'TREATMENT', 'BASELINE')                     AS phase,
    CURRENT_ROLE()                                                  AS primary_role,
    IS_ROLE_IN_SESSION('AGOV_GOVERNOR')                             AS governor_secondary,
    SYS_CONTEXT('SNOWFLAKE$CURRENT','IS_AGENT_ACTIVATED')          AS is_agent_activated;
-- Expected (both phases): primary_role = AGOV_ANALYST, governor_secondary = TRUE,
-- is_agent_activated = FALSE.

SELECT
    EMAIL,
    COUNT(*) AS visible_rows
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS
GROUP BY EMAIL
ORDER BY visible_rows DESC
LIMIT 5;
-- Expected (both phases): many rows of real plaintext emails. The governor
-- secondary role clears masking and AGG_POLICY; the agent RSS property does not
-- restrict human queries.

-- ---------------------------------------------------------------------------
-- R.2  AGENT: same session, same roles, same question as the 02-04 beats
-- ---------------------------------------------------------------------------
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
    'R.2: agent (headless proxy)' AS scenario,
    IFF($rss_attached, 'TREATMENT', 'BASELINE')                         AS phase,
    IFF($rss_attached, 'EXCLUDED-FROM-AGENTIC-USE', 'PLAINTEXT')        AS expected_agent_result,
    LENGTH(TRIM(COALESCE(tool_outputs, ''))) > 0                        AS has_tool_output,
    CONTAINS(COALESCE(tool_outputs, ''), '***EXCLUDED-FROM-AGENTIC-USE***') AS sentinel_in_tool_outputs,
    CASE
        WHEN LENGTH(TRIM(COALESCE(tool_outputs, ''))) = 0 THEN 'NO_TOOL_OUTPUT'
        WHEN CONTAINS(tool_outputs, '***EXCLUDED-FROM-AGENTIC-USE***') THEN 'EXCLUSION_SENTINEL_PRESENT'
        ELSE 'INSPECT_TOOL_DATA'
    END                                                                 AS observed_result,
    tool_outputs,
    agent_answer
FROM parsed;
-- has_tool_output = FALSE (observed_result = NO_TOOL_OUTPUT) means the agent
-- returned no tool data; the run proves nothing for either phase. Re-run.
-- Neither a non-empty tool_outputs nor the absence of the sentinel proves
-- plaintext. Confirm by reading tool_outputs itself: it must show a successful
-- tool execution with actual FULL_NAME/EMAIL values.
-- Expected:
--   BASELINE   observed_result = INSPECT_TOOL_DATA; tool_outputs show a successful
--              execution returning real FULL_NAME/EMAIL values.
--   TREATMENT  observed_result = EXCLUSION_SENTINEL_PRESENT; tool_outputs show a
--              successful execution where every FULL_NAME/EMAIL is the sentinel.
--              The agent still executes; RSS excluded AGOV_GOVERNOR from its secondaries.

SELECT
    'R.3: outer session after agent call'  AS scenario,
    IS_ROLE_IN_SESSION('AGOV_GOVERNOR')     AS governor_still_secondary;
-- Expected (both phases): TRUE. RSS narrows the agent's execution context only,
-- not the calling session's roles.
