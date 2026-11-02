/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale
Part:         PART 2 - Agentic Governance
Section:      02-03 - Contextual Governance via AGENT IDENTITY (the climax)
Persona:      AGOV_GOVERNOR (data custodian) + AGOV_ANALYST and AGOV_ENGINEER (contrast personas)
Story beat:   The hardest question: even when a user CAN access data, should an AGENT acting on their
              behalf be allowed to use it in THIS context? Agent Identity makes this a deterministic,
              auditable control. The custodian adds ONE composable clause to every classification
              policy. UNMASK_ACCESS remains the baseline clear-text capability, but agent execution
              additionally requires AGENTIC_UNMASK_ACCESS. ACCOUNTADMIN remains hard break-glass;
              AGOV_GOVERNOR holds both capabilities. Active role hierarchies without both capabilities
              receive exclusion values for sensitive-tier columns in agent context - WITHOUT changing
              direct RBAC/FGAC at all.

              In this lab we will see, for the SAME EMAIL/FULL_NAME columns: a human or agent
              governor reads them directly; a human analyst sees PII-REDACTED; an agent acting as
              analyst receives an exclusion sentinel. The engineer pair then repeats the human vs
              agent contrast per row, without an aggregate - all six outcomes proved with real
              queries, no simulation.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
Diagram:      images/agent-identity-three-contexts.svg
****************************************************************************************************/

USE ROLE AGOV_GOVERNOR;
USE WAREHOUSE AGOV_WH;
USE DATABASE AGENTIC_GOV_DB;
-- Pin the session to a single role for the whole script so IS_ROLE_IN_SESSION resolves
-- deterministically. Persists across the USE ROLE switches below.
USE SECONDARY ROLES NONE;
-- Run this whole block. Capture the SHOW result explicitly rather than relying
-- on whichever worksheet statement happens to be LAST_QUERY_ID().
EXECUTE IMMEDIATE $$
DECLARE
    show_query_id STRING;
    object_created_at TIMESTAMP_LTZ;
    matching_agents INTEGER;
    missing_agent EXCEPTION (-20002, 'Expected CUSTOMER_INSIGHTS_AGENT; run 02-01 first with the governor role.');
BEGIN
    SHOW AGENTS LIKE 'CUSTOMER_INSIGHTS_AGENT' IN SCHEMA AGENTIC_GOV_DB.AGENTS;
    show_query_id := SQLID;
    SELECT COUNT(*), MAX("created_on") INTO :matching_agents, :object_created_at
    FROM TABLE(RESULT_SCAN(:show_query_id))
    WHERE "name" = 'CUSTOMER_INSIGHTS_AGENT';
    IF (matching_agents <> 1) THEN
        RAISE missing_agent;
    END IF;
    SET agent_created_at = :object_created_at;
END;
$$;

-- ============================================================================
-- 02-03.1  THE AGENT IDENTITY SIGNAL: IS_AGENT_ACTIVATED
--      In a normal human session this is FALSE; inside agent execution it is TRUE.
-- ============================================================================
SELECT
    SYS_CONTEXT('SNOWFLAKE$CURRENT','IS_AGENT_ACTIVATED') AS is_agent_activated,
    CURRENT_USER()  AS current_user,
    CURRENT_ROLE()  AS current_role;

-- ============================================================================
-- 02-03.2  MAKE THE EXISTING TAG-BASED MASKING ROLE-AWARE AND AGENT-AWARE
--      Agent Identity is NOT a separate, orthogonal policy: it is composed into every
--      DATA_CLASSIFICATION masking policy. UNMASK_ACCESS remains the baseline clear-text
--      capability. During agent execution it must be paired with AGENTIC_UNMASK_ACCESS;
--      this co-clearance grants nothing by itself. ACCOUNTADMIN remains hard break-glass.
--      Sensitive tiers are excluded when the agent branch has no paired clearance, while
--      direct non-privileged access continues to use the existing classification masks.
-- ============================================================================
ALTER MASKING POLICY AGENTIC_GOV_DB.GOVERNANCE.MASK_BY_CLASSIFICATION_STRING SET BODY ->
  CASE
    -- Hard break-glass is independent of execution context.
    WHEN IS_ROLE_IN_SESSION('ACCOUNTADMIN') THEN VAL
    -- Agent context: clear text requires baseline clearance AND agent co-clearance.
    WHEN SYS_CONTEXT('SNOWFLAKE$CURRENT','IS_AGENT_ACTIVATED')::BOOLEAN THEN
      CASE
        WHEN IS_DATABASE_ROLE_IN_SESSION('UNMASK_ACCESS')
         AND IS_ROLE_IN_SESSION('AGENTIC_UNMASK_ACCESS') THEN VAL
        WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION')
             IN ('PII','RESTRICTED','SENSITIVE') THEN '***EXCLUDED-FROM-AGENTIC-USE***'
        ELSE VAL
      END
    -- Human context: baseline clearance is sufficient.
    WHEN IS_DATABASE_ROLE_IN_SESSION('UNMASK_ACCESS') THEN VAL
    ELSE
      CASE SYSTEM$GET_TAG_ON_CURRENT_COLUMN('AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION')
        WHEN 'PII'        THEN '***PII-REDACTED***'
        WHEN 'RESTRICTED' THEN CONCAT('***-', RIGHT(VAL, 4))
        WHEN 'SENSITIVE'  THEN SHA2(VAL, 256)
        ELSE VAL
      END
  END;

-- The SAME role-aware agent clause composed into the DATE policy (a date can't carry a string
-- sentinel, so the agentic exclusion returns NULL). One clause, added to every tag-bound policy.
ALTER MASKING POLICY AGENTIC_GOV_DB.GOVERNANCE.MASK_BY_CLASSIFICATION_DATE SET BODY ->
  CASE
    WHEN IS_ROLE_IN_SESSION('ACCOUNTADMIN') THEN VAL
    WHEN SYS_CONTEXT('SNOWFLAKE$CURRENT','IS_AGENT_ACTIVATED')::BOOLEAN THEN
      CASE
        WHEN IS_DATABASE_ROLE_IN_SESSION('UNMASK_ACCESS')
         AND IS_ROLE_IN_SESSION('AGENTIC_UNMASK_ACCESS') THEN VAL
        WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION')
             IN ('PII','RESTRICTED','SENSITIVE') THEN NULL
        ELSE VAL
      END
    WHEN IS_DATABASE_ROLE_IN_SESSION('UNMASK_ACCESS') THEN VAL
    ELSE
      CASE SYSTEM$GET_TAG_ON_CURRENT_COLUMN('AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION')
        WHEN 'PII'        THEN NULL
        WHEN 'RESTRICTED' THEN DATE_TRUNC('YEAR', VAL)
        WHEN 'SENSITIVE'  THEN DATE_TRUNC('MONTH', VAL)
        ELSE VAL
      END
  END;

-- ============================================================================
-- 02-03.3  DETERMINISTIC PROOF: same EMAIL/FULL_NAME columns, six directly verifiable outcomes
--      Every context below runs as a REAL, active session role with USE SECONDARY ROLES NONE,
--      so the IS_ROLE_IN_SESSION checks in the policy resolve to exactly one role - no simulation.
--      DATA_AGENT_RUN executes as the CALLER'S ACTIVE SESSION ROLE, exactly like any other SQL
--      statement issued in that session - it is not tied to a separate DEFAULT_ROLE property.
--      Switching USE ROLE before each call is therefore enough to flip which branch of the
--      role-aware masking clause fires, for BOTH the direct query and the real agent call.
--
--      EMAIL/FULL_NAME (not SSN) are used here because they are the sensitive-tier columns
--      actually exposed by CUSTOMER_ANALYTICS_SV (SSN/CREDITCARD are absent from the view -
--      that boundary was already proved in 02-02).
--
--      Classify every agent outcome strictly from tool_result (the raw JSON the Cortex Analyst
--      tool returned to the model) - NEVER from the agent's natural-language answer. The answer
--      is a paraphrase generated by the LLM and is not authoritative; tool_result is the ground
--      truth of what data the tool actually returned.
-- ============================================================================

-- (A) HUMAN governor, direct semantic-view query -> plaintext FULL_NAME/EMAIL
--     AGOV_GOVERNOR holds UNMASK_ACCESS and is exempt from AGG_POLICY
--     (NO_AGGREGATION_CONSTRAINT, 01-02 section 2.8), so a per-row,
--     DIMENSIONS-only query is safe.
USE ROLE AGOV_GOVERNOR;
USE SECONDARY ROLES NONE;
SELECT 'A: human governor (direct)' AS scenario, * FROM SEMANTIC_VIEW(
    AGENTIC_GOV_DB.GOLD.CUSTOMER_ANALYTICS_SV
    DIMENSIONS analytics.full_name, analytics.email
) LIMIT 5;
-- Expected: real FULL_NAME/EMAIL values - direct access requires only UNMASK_ACCESS.

-- (B) AGENT, caller's active role = AGOV_GOVERNOR -> plaintext (holds both clear-text capabilities)
WITH r AS (
    SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
        'AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT',
        $${"messages":[{"role":"user","content":[{"type":"text","text":"List 5 customers with their full name and email address."}]}]}$$,
        TRUE
    ) AS raw
),
parsed AS (
    SELECT
        ARRAY_AGG(CASE WHEN f.value:type::STRING = 'tool_result'
                       AND f.value:tool_result:content[0]:json:result_set IS NOT NULL
                     THEN f.value:tool_result END) WITHIN GROUP (ORDER BY f.index) AS tool_results,
        MAX(CASE WHEN f.value:type::STRING = 'text'
             THEN TRIM(f.value:text::STRING) END)                                  AS agent_answer_not_authoritative
    FROM r, LATERAL FLATTEN(input => PARSE_JSON(r.raw):content, OUTER => TRUE) f
)
SELECT 'B: agent, active role = AGOV_GOVERNOR' AS scenario, tool_results, agent_answer_not_authoritative
FROM parsed;
SET governor_proof_query_id = LAST_QUERY_ID();
-- Expected: ordered tool_results shows real FULL_NAME/EMAIL values and query IDs.
-- agent_answer_not_authoritative is included only for contrast, not as evidence.

-- (C) HUMAN analyst, direct semantic-view query, aggregation-policy compliant -> ***PII-REDACTED***
--     AGOV_ANALYST is non-exempt from AGG_POLICY (MIN_GROUP_SIZE => 100, 01-02 section 2.8),
--     inherited by CUSTOMER_ANALYTICS_SV from the underlying SILVER dynamic table. A per-row,
--     DIMENSIONS-only query would violate that group-size floor. Adding a METRIC forces the semantic
--     view to aggregate by EMAIL - and because MASK_BY_CLASSIFICATION_STRING has already collapsed
--     every analyst-visible EMAIL to the SAME '***PII-REDACTED***' literal, grouping by EMAIL forms
--     exactly one compliant group spanning every visible row (same pattern as 02-04.1's GROUP BY EMAIL).
USE ROLE AGOV_ANALYST;
USE SECONDARY ROLES NONE;
SELECT 'C: human analyst (direct)' AS scenario, * FROM SEMANTIC_VIEW(
    AGENTIC_GOV_DB.GOLD.CUSTOMER_ANALYTICS_SV
    DIMENSIONS analytics.email
    METRICS analytics.total_orders
) ORDER BY total_orders DESC LIMIT 5;
-- Expected: exactly ONE row - EMAIL = '***PII-REDACTED***', total_orders = every order the analyst
-- can see. PII tier, no agent activation -> the agent clause does not fire.

-- (D) AGENT, caller's active role = AGOV_ANALYST -> ***EXCLUDED-FROM-AGENTIC-USE***
WITH r AS (
    SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
        'AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT',
        $${"messages":[{"role":"user","content":[{"type":"text","text":"List 5 customers with their full name and email address."}]}]}$$,
        TRUE
    ) AS raw
),
parsed AS (
    SELECT
        ARRAY_AGG(CASE WHEN f.value:type::STRING = 'tool_result'
                       AND f.value:tool_result:content[0]:json:result_set IS NOT NULL
                     THEN f.value:tool_result END) WITHIN GROUP (ORDER BY f.index) AS tool_results,
        MAX(CASE WHEN f.value:type::STRING = 'text'
             THEN TRIM(f.value:text::STRING) END)                                  AS agent_answer_not_authoritative
    FROM r, LATERAL FLATTEN(input => PARSE_JSON(r.raw):content, OUTER => TRUE) f
)
SELECT 'D: agent, active role = AGOV_ANALYST' AS scenario, tool_results, agent_answer_not_authoritative
FROM parsed;
SET analyst_proof_query_id = LAST_QUERY_ID();
-- Expected: tool_results shows every EMAIL/FULL_NAME as '***EXCLUDED-FROM-AGENTIC-USE***' -
-- the non-exempt role fails the privileged check, agent activation is TRUE, and the sensitive tier
-- excludes the column entirely. Compare directly to C above: SAME role, SAME EMAIL column, two different
-- outcomes - masking alone (PII-REDACTED) vs. agent-mediated exclusion (EXCLUDED-FROM-AGENTIC-USE).

-- (E) HUMAN engineer, direct per-row semantic-view query -> hashed FULL_NAME, ***PII-REDACTED*** EMAIL
--     AGOV_ENGINEER holds UNAGGREGATED_ACCESS (01-02 section 2.8), so the per-row,
--     DIMENSIONS-only query is valid without a metric. It holds neither UNMASK_ACCESS nor
--     AGENTIC_UNMASK_ACCESS, so the human classification masks apply.
USE ROLE AGOV_ENGINEER;
USE SECONDARY ROLES NONE;
SELECT 'E: human engineer (direct)' AS scenario, * FROM SEMANTIC_VIEW(
    AGENTIC_GOV_DB.GOLD.CUSTOMER_ANALYTICS_SV
    DIMENSIONS analytics.customer_id, analytics.order_id, analytics.full_name, analytics.email
) ORDER BY customer_id, order_id LIMIT 5;
-- Expected: five rows with FULL_NAME as a SHA2 hash (SENSITIVE tier) and EMAIL as
-- '***PII-REDACTED***' (PII tier). No agent activation, so the agent clause does not fire.

-- (F) AGENT, caller's active role = AGOV_ENGINEER -> ***EXCLUDED-FROM-AGENTIC-USE***
--     The same role and the same per-row request, now through the agent.
WITH r AS (
    SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
        'AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT',
        $${"messages":[{"role":"user","content":[{"type":"text","text":"List 5 individual order rows with customer ID, order ID, full name and email address, ordered by customer ID then order ID. Do not aggregate."}]}]}$$,
        TRUE
    ) AS raw
),
parsed AS (
    SELECT
        ARRAY_AGG(CASE WHEN f.value:type::STRING = 'tool_result'
                       AND f.value:tool_result:content[0]:json:result_set IS NOT NULL
                      THEN f.value:tool_result END) WITHIN GROUP (ORDER BY f.index) AS tool_results,
        MAX(CASE WHEN f.value:type::STRING = 'text'
             THEN TRIM(f.value:text::STRING) END)                                   AS agent_answer_not_authoritative
    FROM r, LATERAL FLATTEN(input => PARSE_JSON(r.raw):content, OUTER => TRUE) f
)
SELECT 'F: agent, active role = AGOV_ENGINEER' AS scenario, tool_results, agent_answer_not_authoritative
FROM parsed;
SET engineer_proof_query_id = LAST_QUERY_ID();
-- Expected: tool_results shows FULL_NAME and EMAIL as '***EXCLUDED-FROM-AGENTIC-USE***' on each row.
-- Compare directly to E: SAME role, SAME per-row shape, two different outcomes - human masks
-- (hash, PII-REDACTED) vs. agent-mediated exclusion. Check the generated SQL in tool_results for a
-- per-row query; the agent's answer is a paraphrase, not evidence.

/*  Expected summary:
    A: human governor (direct)             -> real FULL_NAME / EMAIL       (UNMASK_ACCESS)
    B: agent, active role = AGOV_GOVERNOR  -> real FULL_NAME / EMAIL       (UNMASK_ACCESS + AGENTIC_UNMASK_ACCESS)
    C: human analyst (direct)              -> ***PII-REDACTED***           (PII tier, no agent activation)
    D: agent, active role = AGOV_ANALYST   -> ***EXCLUDED-FROM-AGENTIC-USE*** (agent clause fires)
    E: human engineer (direct, per row)    -> hashed FULL_NAME / ***PII-REDACTED*** EMAIL (human masks)
    F: agent, active role = AGOV_ENGINEER  -> ***EXCLUDED-FROM-AGENTIC-USE*** (agent clause fires)
*/

-- ============================================================================
-- 02-03.4  ATTRIBUTION: SQL execution, request traces, and usage
--      Query History describes SQL, not every tool invocation. AGENT_TYPE identifies
--      agent-initiated SQL; the cortex-agent-{request_id} tag correlates this agent's
--      requests. Retain query_id from tool results for exact statement lookup.
--      Usage rows can lag up to one hour; SQL cost metadata can lag up to eight hours.
--      Trace delivery is best effort. Use usage views, not span sums, for billing.
-- ============================================================================

-- 1. Request identity: native API/SQL and CoWork have separate usage views.
--    AGOV_AUDITOR holds GOVERNANCE_VIEWER which grants Account Usage access.
--
--    AGENT_ID identifies an object incarnation, not its mutable configuration.
--    Retain account, agent ID, and the invoked version where available in traces.
--    Scope evidence to this run's creation time and fully qualified agent name.
--    SHOW AGENTS does not expose an agent_id column on every supported version.
USE ROLE AGOV_AUDITOR;
USE WAREHOUSE AGOV_WH;
WITH requests AS (
    SELECT 'CORTEX_AGENT' AS usage_source, AGENT_ID, REQUEST_ID, PARENT_REQUEST_ID,
           AGENT_DATABASE_NAME, AGENT_SCHEMA_NAME, AGENT_NAME, USER_NAME,
           METADATA, START_TIME, END_TIME, TOKENS, TOKEN_CREDITS
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
    WHERE START_TIME >= $agent_created_at
    UNION ALL
    SELECT 'COWORK', AGENT_ID, REQUEST_ID, PARENT_REQUEST_ID,
           AGENT_DATABASE_NAME, AGENT_SCHEMA_NAME, AGENT_NAME, USER_NAME,
           METADATA, START_TIME, END_TIME, TOKENS, TOKEN_CREDITS
    FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COWORK_USAGE_HISTORY
    WHERE START_TIME >= $agent_created_at
)
SELECT
    usage_source,
    AGENT_ID,
    REQUEST_ID,
    PARENT_REQUEST_ID,
    AGENT_DATABASE_NAME || '.' || AGENT_SCHEMA_NAME || '.' || AGENT_NAME      AS agent_fqn,
    USER_NAME,
    METADATA:role_name::STRING                                                 AS role_name,
    METADATA:interaction_interface::STRING                                     AS interface,
    START_TIME,
    DATEDIFF('millisecond', START_TIME, END_TIME)                             AS duration_ms,
    TOKENS,
    TOKEN_CREDITS
FROM requests
WHERE AGENT_NAME = 'CUSTOMER_INSIGHTS_AGENT'
  AND AGENT_DATABASE_NAME = 'AGENTIC_GOV_DB' AND AGENT_SCHEMA_NAME = 'AGENTS'
  AND START_TIME >= $agent_created_at
ORDER BY START_TIME DESC
LIMIT 10;


-- 2. Exact SQL IDs from the three proof results above. RESULT_SCAN is session/user
--    evidence with a 24-hour lifetime; rerun the proof to obtain fresh handles.
--    Query History function limits apply before filtering; an unmatched query ID
--    remains visible. Narrow/split time windows on busy accounts if necessary.
--    SYSADMIN owns AGOV_WH (MONITOR) and RESULT_SCAN is scoped to your user.
USE ROLE SYSADMIN;
WITH proof AS (
    SELECT SCENARIO, TOOL_RESULTS FROM TABLE(RESULT_SCAN($governor_proof_query_id))
    UNION ALL
    SELECT SCENARIO, TOOL_RESULTS FROM TABLE(RESULT_SCAN($analyst_proof_query_id))
    UNION ALL
    SELECT SCENARIO, TOOL_RESULTS FROM TABLE(RESULT_SCAN($engineer_proof_query_id))
), tool_queries AS (
    SELECT DISTINCT p.SCENARIO, c.value:json:query_id::STRING AS query_id
    FROM proof p, LATERAL FLATTEN(INPUT => p.TOOL_RESULTS) t,
         LATERAL FLATTEN(INPUT => t.value:content) c
    WHERE c.value:json:query_id IS NOT NULL
), history AS (
    SELECT * FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.QUERY_HISTORY(
        END_TIME_RANGE_START => $agent_created_at, RESULT_LIMIT => 10000))
)
SELECT
    t.SCENARIO, t.QUERY_ID,
    REPLACE(q.QUERY_TAG, 'cortex-agent-', '') AS request_id,
    q.AGENT_TYPE, q.EXECUTION_STATUS, q.ERROR_CODE, q.ERROR_MESSAGE,
    q.USER_NAME AS execution_user, q.ROLE_NAME AS execution_role,
    q.QUERY_TEXT AS sql_run_by_agent, q.TOTAL_ELAPSED_TIME AS elapsed_ms,
    q.ROWS_WRITTEN_TO_RESULT, q.START_TIME,
    IFF(q.QUERY_ID IS NULL, 'PENDING_OR_OUTSIDE_WINDOW', 'MATCHED') AS correlation_status
FROM tool_queries t LEFT JOIN history q ON q.QUERY_ID = t.QUERY_ID
ORDER BY t.SCENARIO, q.START_TIME;

-- 3. Object-scoped trace: one turn/trace contains multiple execution spans.
--    Filter TRACE:trace_id for one turn; tool spans can carry exact SQL query IDs.
--    Metadata remains visible without the unredacted-content privilege from 02-01.
--    Empty results mean no delivered evidence yet, not that no activity occurred.
USE ROLE AGOV_GOVERNOR;
SELECT TIMESTAMP, TRACE:trace_id::STRING AS trace_id, TRACE:span_id::STRING AS span_id,
       RECORD:name::STRING AS span_name,
       RECORD_ATTRIBUTES:"snow.ai.observability.agent.thread_id"::STRING AS thread_id,
       RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.request_id"::STRING AS sql_request_id,
       RECORD_ATTRIBUTES:"snow.ai.observability.agent.tool.sql_execution.query_id"::STRING AS query_id,
       RESOURCE_ATTRIBUTES, RECORD_ATTRIBUTES
FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
    'AGENTIC_GOV_DB','AGENTS','CUSTOMER_INSIGHTS_AGENT','CORTEX AGENT'))
WHERE TIMESTAMP >= CONVERT_TIMEZONE('UTC', $agent_created_at)::TIMESTAMP_NTZ
ORDER BY TIMESTAMP, trace_id, span_id;

-- 4. Delayed correlation preserves requests without a matching SQL row.
--    NO_SQL_MATCH does not distinguish non-SQL requests, pre-execution denials,
--    and telemetry still in transit. Consult the corresponding tool trace.
--    One request can join to many SQL statements: never sum request credits here.
USE ROLE AGOV_AUDITOR;
WITH requests AS (
    SELECT 'CORTEX_AGENT' AS usage_source, AGENT_ID, REQUEST_ID, PARENT_REQUEST_ID,
           AGENT_DATABASE_NAME, AGENT_SCHEMA_NAME, AGENT_NAME, USER_NAME, METADATA, START_TIME
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
    WHERE START_TIME >= $agent_created_at
    UNION ALL
    SELECT 'COWORK', AGENT_ID, REQUEST_ID, PARENT_REQUEST_ID,
           AGENT_DATABASE_NAME, AGENT_SCHEMA_NAME, AGENT_NAME, USER_NAME, METADATA, START_TIME
    FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COWORK_USAGE_HISTORY
    WHERE START_TIME >= $agent_created_at
)
SELECT
    a.usage_source,
    a.AGENT_ID,
    a.REQUEST_ID,
    a.PARENT_REQUEST_ID,
    a.AGENT_DATABASE_NAME || '.' || a.AGENT_SCHEMA_NAME || '.' || a.AGENT_NAME AS agent_fqn,
    a.USER_NAME AS request_user,
    a.METADATA:role_name::STRING AS request_role,
    q.USER_NAME AS execution_user, q.ROLE_NAME AS execution_role,
    q.QUERY_ID, q.AGENT_TYPE, q.EXECUTION_STATUS, q.ERROR_CODE, q.ERROR_MESSAGE,
    IFF(q.QUERY_ID IS NULL, 'NO_SQL_MATCH', 'MATCHED') AS correlation_status,
    a.METADATA:interaction_interface::STRING                                   AS interface,
    LEFT(q.QUERY_TEXT, 300)                                                    AS sql_run_by_agent,
    q.ROWS_PRODUCED,
    q.START_TIME                                                               AS tool_call_time
FROM requests a
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  ON q.QUERY_TAG = 'cortex-agent-' || a.REQUEST_ID
 AND q.START_TIME >= $agent_created_at
WHERE a.AGENT_NAME = 'CUSTOMER_INSIGHTS_AGENT'
  AND a.AGENT_DATABASE_NAME = 'AGENTIC_GOV_DB' AND a.AGENT_SCHEMA_NAME = 'AGENTS'
  AND a.START_TIME >= $agent_created_at
ORDER BY a.START_TIME DESC, q.START_TIME ASC;

