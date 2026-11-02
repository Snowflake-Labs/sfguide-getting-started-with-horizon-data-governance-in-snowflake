/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale
Part:         PART 2 - Agentic Governance
Section:      02-01 - Capability Governance (controls ON the agent: which model, which agent, which tools)
Persona:      AGOV_GOVERNOR (data custodian)
Story beat:   Capability governance decides WHAT MAY EXIST: which model, which agent, which tools.
              First we approve WHICH MODELS a role may use (model RBAC). Then we approve ONE
              narrowly-scoped Cortex Agent over the governed GOLD semantic view from Part 1 (01-02).
              This is "yes, but only this model, only this agent, only these tools." It does NOT decide
              whether a user may use it on a given datum in context - that is 02-03 (Agent Identity).
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
Diagram:      images/capability-governance.svg
****************************************************************************************************/

USE ROLE AGOV_GOVERNOR;
USE WAREHOUSE AGOV_WH;
USE DATABASE AGENTIC_GOV_DB;
USE SCHEMA AGENTS;
-- Pin the session to a single role for the whole script (persists across USE ROLE below),
-- so the model-RBAC enforcement check reflects only the analyst's own grants, not inherited ones.
USE SECONDARY ROLES NONE;

-- ============================================================================
-- 02-01.1  MODEL RBAC: approve WHICH MODELS a role may use
--      The first capability decision is the model itself. Cortex models are
--      governable like any object via SNOWFLAKE.MODELS + application roles.
--      We approve exactly one model (Claude Sonnet 5) for the analyst on a clean run.
--
--      Model authorization is additive: access succeeds when either model RBAC OR
--      CORTEX_MODELS_ALLOWLIST permits the model. Accounts migrated from allowlist
--      = All also inherit CORTEX-MODEL-ROLE-ALL through SNOWFLAKE.PUBLIC. A fully
--      qualified SNOWFLAKE.MODELS identifier does not bypass either broad path.
--
--      This lab therefore switches the account to RBAC-only model authorization:
--        1. Remove the Snowflake-managed all-model bootstrap from SNOWFLAKE.PUBLIC.
--        2. Set the deprecated allowlist fallback to None.
--        3. Grant only the approved model application role to AGOV_ANALYST.
--
--      ACCOUNT-WIDE CHANGE: 99-Teardown restores the SNOWFLAKE.PUBLIC all-model
--      bootstrap. CORTEX_MODELS_ALLOWLIST remains None because, during its 2026
--      retirement, Snowflake no longer permits changing it back to All.
--      Record the current PUBLIC grants and allowlist first: 00-Setup section 0.0
--      CAPTURE PRIOR SETTINGS (C.2, C.4, C.5). Run it now if you skipped it.
-- ACCOUNTADMIN required: model catalog refresh, SNOWFLAKE.LOCAL bootstrap procedure,
-- SNOWFLAKE application-role grants, and the CORTEX_MODELS_ALLOWLIST account parameter
-- (https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql-privileges-and-access).
-- ============================================================================
USE ROLE ACCOUNTADMIN;

-- Populate SNOWFLAKE.MODELS and create per-model application roles.
-- Setup leaves this optional call commented too. Verify catalog availability first.
-- Uncomment if you are running 02-01 standalone on a fresh account. It takes several
-- minutes (around 5 min observed); wait until it completes before the grants below.
-- CALL SNOWFLAKE.MODELS.CORTEX_BASE_MODELS_REFRESH();

-- Remove broad access inherited by every account role through PUBLIC. Use the
-- supported procedure: a raw REVOKE from account role PUBLIC does not remove the
-- Snowflake-managed bootstrap and does not persist across upgrades.
CALL SNOWFLAKE.LOCAL.REVOKE_FROM_PUBLIC_APPLICATION_ROLE(
    'APP_ROLE',
    'CORTEX-MODEL-ROLE-ALL'
);

-- Remove a customer-managed grant too, if one exists. This is a separate path
-- from the Snowflake-managed SNOWFLAKE.PUBLIC bootstrap above.
REVOKE APPLICATION ROLE SNOWFLAKE."CORTEX-MODEL-ROLE-ALL" FROM ROLE PUBLIC;

-- Disable the legacy allowlist fallback so model application roles are the sole
-- model-authorization path.
ALTER ACCOUNT SET CORTEX_MODELS_ALLOWLIST = 'None';

-- Approve Sonnet 5; the governor also needs the Part 4 / Part 5 function models.
GRANT APPLICATION ROLE SNOWFLAKE."CORTEX-MODEL-ROLE-CLAUDE-SONNET-5" TO ROLE AGOV_ANALYST;
GRANT APPLICATION ROLE SNOWFLAKE."CORTEX-MODEL-ROLE-CLAUDE-SONNET-5" TO ROLE AGOV_GOVERNOR;
GRANT APPLICATION ROLE SNOWFLAKE."CORTEX-MODEL-ROLE-CLAUDE-SONNET-5" TO ROLE AGOV_ENGINEER;
GRANT APPLICATION ROLE SNOWFLAKE."CORTEX-MODEL-ROLE-LLAMA3.1-70B" TO ROLE AGOV_GOVERNOR;      -- AI_REDACT
GRANT APPLICATION ROLE SNOWFLAKE."CORTEX-MODEL-ROLE-ARCTIC-SENTIMENT" TO ROLE AGOV_GOVERNOR;  -- AI_SENTIMENT

-- Enforcement check as the analyst (secondary roles already disabled at the top so
-- ACCOUNTADMIN / inherited grants can't mask the result).
USE ROLE AGOV_ANALYST;
USE WAREHOUSE AGOV_WH;

-- APPROVED model -> succeeds
SELECT AI_COMPLETE('SNOWFLAKE.MODELS."CLAUDE-SONNET-5"', 'Reply with the single word OK') AS approved_model;

-- UNAPPROVED model -> blocked by model RBAC. Uncomment to see the governance error
-- ("...not authorized to use model... CLAUDE-OPUS-4-5"); left commented so the script runs clean.
-- If CLAUDE-OPUS-4-5 is unavailable in your region, use any catalog model not granted to this role.
-- SELECT AI_COMPLETE('SNOWFLAKE.MODELS."CLAUDE-OPUS-4-5"', 'Reply with the single word OK') AS denied_model;

-- ============================================================================
-- 02-01.2  Create and approve one agent  (narrow scope, single Cortex Analyst tool)
--      The agent's only tool is the GOVERNED semantic view from Part 1 (01-02).
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
USE WAREHOUSE AGOV_WH;
USE SCHEMA AGENTIC_GOV_DB.AGENTS;
CREATE OR REPLACE AGENT AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT
  COMMENT = 'Approved customer-insights agent: read-only analytics over the governed semantic view'
  PROFILE = '{"display_name": "Customer Insights Agent", "color": "blue"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: claude-sonnet-5

  instructions:
    response: >
      Report the Customer Analytics tool's results exactly as returned, including any
      masked or excluded sentinel values. Snowflake governance policies (masking, row
      access, agent identity, Restricted Session Scope) already control what value you
      receive before it reaches you - do not refuse or further redact based on a column's
      name. This is a governed analytics environment; your job is to report the governed
      result verbatim, not to second-guess it.
    orchestration: >
      For any customer, order, revenue, or state question, always call the Customer
      Analytics tool and report its result. Never decline to call the tool because a
      column name looks sensitive (e.g. email, name, ssn) - masking, exclusion, and row
      filtering are enforced by Snowflake governance policies inside the tool, not by you.
    sample_questions:
      - question: "What is total revenue by state?"
      - question: "How many orders do we have by currency?"

  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "customer_analytics"
        description: "Converts natural-language questions about customers, orders, revenue, and state into SQL over the governed customer analytics semantic view. Use for all customer/order/revenue questions. Do not use for anything outside customer order analytics."

  tool_resources:
    customer_analytics:
      semantic_view: "AGENTIC_GOV_DB.GOLD.CUSTOMER_ANALYTICS_SV"
      execution_environment:
        type: "warehouse"
        warehouse: "AGOV_WH"
  $$;

SHOW AGENTS LIKE 'CUSTOMER_INSIGHTS_AGENT' IN SCHEMA AGENTIC_GOV_DB.AGENTS;

-- Approve the analyst to USE the agent (capability grant). Governance still applies:
-- the agent runs under the analyst's own FGAC and the semantic-view boundary.
GRANT USAGE ON AGENT AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT TO ROLE AGOV_ANALYST;
-- The engineer is approved too, for the 02-03 per-row Agent Identity comparison.
-- Agent usage grants no unmask capability: masking still follows the engineer's role.
GRANT USAGE ON AGENT AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT TO ROLE AGOV_ENGINEER;

-- ============================================================================
-- 02-01.3  OBSERVABILITY CONTENT IS A SEPARATE CAPABILITY
--      The governor owns the agent, so it can inspect agent metadata and traces.
--      Ownership alone does NOT reveal raw conversation content, tool inputs/outputs,
--      or model thinking: Snowflake redacts those fields until the account-level
--      READ UNREDACTED AI OBSERVABILITY EVENTS TABLE privilege is explicitly granted.
--      This is intentional least privilege: operational monitoring does not imply
--      access to potentially sensitive prompt and result content.
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
USE WAREHOUSE AGOV_WH;

-- Seed a trace after agent creation. AI observability is delivered asynchronously,
-- so the trace-query steps below can initially return no rows; rerun them after the
-- event is available rather than treating an empty result as an access failure.
WITH r AS (
    SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
        'AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT',
        $${"messages":[{"role":"user","content":[{"type":"text","text":"How many distinct customers are there in total?"}]}]}$$,
        TRUE
    ) AS raw
)
SELECT TRIM(f.value:text::STRING) AS seed_agent_answer
FROM r, LATERAL FLATTEN(input => PARSE_JSON(r.raw):content) f
WHERE f.value:type::STRING = 'text';

-- First remove any prior lab-run grant. The following trace query still returns
-- event metadata, but raw content fields in RECORD_ATTRIBUTES are redacted.
-- ACCOUNTADMIN required: SECURITYADMIN is rejected for this privilege, and a revoke
-- must come from the grantor (rehearsal 2026-11-02)
USE ROLE ACCOUNTADMIN;
REVOKE READ UNREDACTED AI OBSERVABILITY EVENTS TABLE ON ACCOUNT FROM ROLE AGOV_GOVERNOR;

USE ROLE AGOV_GOVERNOR;
SELECT
    RECORD:name::STRING AS event_name,
    RECORD_ATTRIBUTES
FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
    'AGENTIC_GOV_DB', 'AGENTS', 'CUSTOMER_INSIGHTS_AGENT', 'CORTEX AGENT'
))
WHERE RECORD:name::STRING ILIKE '%TOOL%'
ORDER BY TIMESTAMP DESC
LIMIT 5;
-- Expected once the seeded trace is available: the governor can identify the tool/span
-- metadata but sees the warning "Some data is redacted" and no raw conversation,
-- tool, or thinking content. If no rows return yet, wait for telemetry delivery and
-- rerun this query before proceeding to the grant.

-- Grant the custodian the narrowly named account privilege. It applies only after
-- the governor already has object-level OWNERSHIP/MONITOR and CORTEX_USER access.
-- ACCOUNTADMIN required: SECURITYADMIN gets Insufficient privileges on this
-- account privilege (rehearsal 2026-11-02)
USE ROLE ACCOUNTADMIN;
GRANT READ UNREDACTED AI OBSERVABILITY EVENTS TABLE ON ACCOUNT TO ROLE AGOV_GOVERNOR;

USE ROLE AGOV_GOVERNOR;
SELECT
    RECORD:name::STRING AS event_name,
    RECORD_ATTRIBUTES
FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
    'AGENTIC_GOV_DB', 'AGENTS', 'CUSTOMER_INSIGHTS_AGENT', 'CORTEX AGENT'
))
WHERE RECORD:name::STRING ILIKE '%TOOL%'
ORDER BY TIMESTAMP DESC
LIMIT 5;
-- Expected once the same trace is available: raw prompt/tool attributes are visible.
-- Available trace content depends on the model and interface. This allows the
-- governor to investigate the ZIP bypass attempt in 02-02 while AGOV_AUDITOR remains
-- limited to metadata-only observability.
