/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale
Part:         PART 5 - AI Cost Governance
Section:      05-05 - Observe AI Cost: Functions, Agents, Attribution & Positioning
Persona:      AGOV_AUDITOR (read-only observer)
Story beat:   Closing the loop: Attribute (00-Setup / 05-01) -> Control (05-02) -> Automate (05-04)
              -> Observe. This is the ONLY file that reads usage history: every earlier file
              defers its "did it work?" check to here, because ACCOUNT_USAGE lags (typically
              under an hour) and budgets lag up to ~6.5h. Run it at the end of the session, or
              the next day.
              5.16-5.18 read ACCOUNT_USAGE (raw consumption, including Part 2 / Part 3 agent
              calls); 5.20 / 5.20a read the budget- and quota-native views (what each control
              counted and fired on). 5.22 (OPTIONAL) shows the rest of Cortex AI: per-service
              views for detail, METERING_HISTORY for the whole picture; 05-06 adds an app
              covering all of it. AI Gateway is queried for architecture completeness: this lab
              generates no AI Gateway usage, but other workloads in the account may.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
****************************************************************************************************/

USE ROLE AGOV_AUDITOR;
USE WAREHOUSE AGOV_WH;
USE DATABASE AGENTIC_GOV_DB;

-- ============================================================================
-- 5.16 AI FUNCTIONS CREDITS BY USER AND COST CENTER (05-03, incl. bulk run)
--      Credits exclude warehouse compute - AI Functions billing is separate
--      from the warehouse that issues the SQL.
--      AI Functions usage history carries neither user_tags nor USER_NAME -
--      only USER_ID and QUERY_ID - so the caller is resolved through
--      QUERY_HISTORY (readable via GOVERNANCE_VIEWER, which AGOV_AUDITOR has;
--      ACCOUNT_USAGE.USERS would need SECURITY_VIEWER), and the cost center is
--      the CURRENT tag, not point-in-time. Acceptable here: the tag is set once
--      in 00-Setup.sql and not changed during the lab.
-- ============================================================================
WITH ai_function_usage AS (
    SELECT h.start_time, qh.user_name, h.function_name,
           COALESCE(NULLIF(h.model_name, ''), 'NOT_APPLICABLE') AS model_name,
           h.query_id, h.credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
    LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
           ON qh.query_id = h.query_id
          AND qh.start_time >= DATEADD('DAY', -31, CURRENT_TIMESTAMP())
    WHERE h.start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
      AND h.function_name IN ('AI_COMPLETE', 'AI_SENTIMENT')
),
current_tags AS (
    SELECT object_name AS user_name, tag_value AS cost_center
    FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
    WHERE domain = 'USER'
      AND tag_database = 'AGENTIC_GOV_DB'
      AND tag_schema   = 'COST_MANAGEMENT'
      AND tag_name     = 'AI_COST_CENTER'
)
SELECT DATE_TRUNC('DAY', u.start_time)::DATE AS usage_day,
       COALESCE(t.cost_center, 'UNTAGGED') AS cost_center,
       u.user_name, u.function_name, u.model_name,
       COUNT(DISTINCT u.query_id) AS queries,
       ROUND(SUM(u.credits), 4) AS ai_credits
FROM ai_function_usage u
LEFT JOIN current_tags t ON t.user_name = u.user_name
GROUP BY 1, 2, 3, 4, 5
ORDER BY usage_day DESC, ai_credits DESC;

-- ============================================================================
-- 5.17 CORTEX AGENT CREDITS BY USER AND COST CENTER (Part 2, Part 3, 05-03)
--      Token credits plus any separately attributed downstream AI Function /
--      SQL costs the agent's tool calls incurred.
--      Cost center comes from USER_TAGS recorded with each request
--      (point-in-time) - the mechanism the budget/quota scoping in 05-02
--      relies on. Calls made before the tag existed stay UNTAGGED.
--      FILTER picks the tag per row without the fan-out of LATERAL FLATTEN.
-- ============================================================================
SELECT DATE_TRUNC('DAY', start_time)::DATE AS usage_day,
       COALESCE(FILTER(user_tags, t -> t:tag_name::STRING = 'AI_COST_CENTER')[0]:tag_value::STRING,
                'UNTAGGED') AS cost_center,
       user_name, agent_name,
       COUNT(*) AS requests,
       SUM(tokens) AS tokens,
       ROUND(SUM(token_credits), 4) AS token_credits,
       ROUND(SUM(COALESCE(metadata:ai_functions_credits::NUMBER, 0)), 4) AS ai_function_credits,
       ROUND(SUM(COALESCE(metadata:sql_query_credits::NUMBER, 0)), 4) AS sql_query_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
WHERE start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
  AND agent_database_name = 'AGENTIC_GOV_DB'
  AND agent_name IN ('CUSTOMER_INSIGHTS_AGENT', 'PIPELINE_OPS_AGENT')
GROUP BY 1, 2, 3, 4
ORDER BY usage_day DESC, token_credits DESC;

-- ============================================================================
-- 5.18 ROLLUP: lab AI credits per service and cost center, month to date
--      The ACCOUNT_USAGE side of 5.20 / 5.20a: compare these rows with
--      what each budget and the quota counted. Month to date to match the
--      budget/quota cycles, and the WHOLE domain per service (every AI
--      function, every agent) because that is what the budgets scope.
-- ============================================================================
WITH t0 AS (SELECT DATE_TRUNC('MONTH', CURRENT_DATE())::TIMESTAMP_LTZ AS t0),
current_tags AS (
    SELECT object_name AS user_name, tag_value AS cost_center
    FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
    WHERE domain = 'USER'
      AND tag_database = 'AGENTIC_GOV_DB'
      AND tag_schema   = 'COST_MANAGEMENT'
      AND tag_name     = 'AI_COST_CENTER'
)
SELECT 'AI FUNCTION' AS service,
       COALESCE(t.cost_center, 'UNTAGGED') AS cost_center,
       ROUND(SUM(h.credits), 4) AS credits_month_to_date
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
CROSS JOIN t0
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
       ON qh.query_id = h.query_id
      AND qh.start_time >= DATEADD('DAY', -1, t0.t0)
LEFT JOIN current_tags t ON t.user_name = qh.user_name
WHERE h.start_time >= t0.t0
GROUP BY 1, 2
UNION ALL
SELECT 'CORTEX AGENT',
       COALESCE(FILTER(a.user_tags, x -> x:tag_name::STRING = 'AI_COST_CENTER')[0]:tag_value::STRING,
                'UNTAGGED'),
       ROUND(SUM(a.token_credits), 4)
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY a
CROSS JOIN t0
WHERE a.start_time >= t0.t0
GROUP BY 1, 2
ORDER BY service, credits_month_to_date DESC;

-- ============================================================================
-- 5.19 AI GATEWAY (architecture completeness only)
--      This lab never calls AI Gateway, so it generates no rows here. Rows
--      that do appear come from other workloads in the account.
--      Kept to show where AI Gateway usage would appear; a third budget with
--      ADD_SHARED_RESOURCE('AI GATEWAY') would track it the same way 05-02
--      tracks agents and AI functions.
-- ============================================================================
SELECT user_id, gateway_name, service_type,
       COUNT(*) AS requests,
       ROUND(SUM(credits), 4) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.AI_GATEWAY_USAGE_HISTORY
GROUP BY user_id, gateway_name, service_type
ORDER BY credits DESC
LIMIT 100;

-- ============================================================================
-- 5.20 BUDGET-NATIVE VIEW: what each budget from 05-02 itself has counted
--      ACCOUNT_USAGE above shows raw consumption; the budget methods below
--      show consumption AS ATTRIBUTED to each budget's scope (user tag x
--      shared resources), which is what thresholds and custom actions fire on.
--      Budget methods require a budget instance role, so this section runs as
--      the budget owner (AGOV_GOVERNOR) rather than AGOV_AUDITOR.
--      Budget data lags (up to ~6.5h on TIER_6H); REFRESH_USAGE() shortens but
--      does not remove that lag. If spend is still 0, run this again later.
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
USE SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT;

SET BUDGET_MONTH_START = TO_CHAR(DATEADD('MONTH', -1, CURRENT_DATE()), 'YYYY-MM');
SET BUDGET_MONTH_END   = TO_CHAR(CURRENT_DATE(), 'YYYY-MM');

CALL AGOV_AGENT_BUDGET!REFRESH_USAGE();
CALL AGOV_AI_FUNCTION_BUDGET!REFRESH_USAGE();

-- Per service and entity, both budgets side by side. Expected: agent rows only
-- under AGOV_AGENT_BUDGET, AI Function rows (AI_COMPLETE, AI_SENTIMENT) only
-- under AGOV_AI_FUNCTION_BUDGET - even though the same user called both.
-- One statement using the pipe operator (->>): $2 is the first CALL's result,
-- $1 the second's. Unlike SET ... = LAST_QUERY_ID() + RESULT_SCAN, it does not
-- break when only this block is run or statements are re-run out of order.
-- In Snowsight, switch the result to Chart -> Bar, X = BUDGET_NAME,
-- Y = CREDITS_USED, Series = NAME (stacked).
-- The agent budget scopes the whole CORTEX AGENT domain, so any other agent
-- the tagged user ran this month also appears here.
CALL AGOV_AGENT_BUDGET!GET_SERVICE_TYPE_USAGE_V2($BUDGET_MONTH_START, $BUDGET_MONTH_END)
->> CALL AGOV_AI_FUNCTION_BUDGET!GET_SERVICE_TYPE_USAGE_V2($BUDGET_MONTH_START, $BUDGET_MONTH_END)
->> SELECT 'AGOV_AGENT_BUDGET' AS budget_name, "SERVICE_TYPE" AS service_type,
           "NAME" AS name, ROUND(SUM("CREDITS_USED"), 6) AS credits_used
    FROM $2
    GROUP BY 2, 3
    UNION ALL
    SELECT 'AGOV_AI_FUNCTION_BUDGET', "SERVICE_TYPE", "NAME",
           ROUND(SUM("CREDITS_USED"), 6)
    FROM $1
    GROUP BY 2, 3
    ORDER BY budget_name, credits_used DESC;

-- Spend vs the 1-credit limit per budget. Chart -> Line over the period column.
CALL AGOV_AGENT_BUDGET!GET_SPENDING_HISTORY();
CALL AGOV_AI_FUNCTION_BUDGET!GET_SPENDING_HISTORY();

-- Did the 1% custom actions (05-04 5.12b) fire? Budget-fired rows have no
-- dry_run flag; they appear only after the budget refresh has seen the spend.
SELECT CONTROL_NAME, ACTION_NAME, THRESHOLD, DETAILS:service::STRING AS service,
       COALESCE(DETAILS:dry_run::BOOLEAN, FALSE) AS dry_run, EVENT_TIME
FROM AGENTIC_GOV_DB.COST_MANAGEMENT.AI_BUDGET_ACTION_LOG
ORDER BY EVENT_TIME DESC;

-- ============================================================================
-- 5.20a QUOTA-NATIVE VIEW: per-user spend against AGOV_AI_QUOTA
--      The quota spans both services, so the user's total here should roughly
--      equal AGOV_AGENT_BUDGET + AGOV_AI_FUNCTION_BUDGET above (subject to each
--      control's refresh timing). One row per user x service.
--      Chart -> Bar, X = user, Y = credits.
-- ============================================================================
SET QUOTA_START = TO_CHAR(DATE_TRUNC('MONTH', CURRENT_DATE()), 'YYYY-MM-DD');
SET QUOTA_END   = TO_CHAR(LAST_DAY(CURRENT_DATE()), 'YYYY-MM-DD');

CALL AGOV_AI_QUOTA!GET_SPENDING_DETAILS_BY_USERS($QUOTA_START, $QUOTA_END)
->> SELECT "USER_NAME" AS user_name, "SERVICE_TYPE" AS service_type,
           ROUND(SUM("CREDITS_SPEND"), 6) AS credits
    FROM $1
    GROUP BY 1, 2
    ORDER BY 1, 2;

USE ROLE AGOV_AUDITOR;

-- ============================================================================
-- 5.21 POSITIONING: where AI Gateway fits (documentation only, nothing to run)
--      AI Gateway is a shared inference entry point for multiple models and
--      AI applications. In this governance design it would provide one place
--      to apply and observe:
--        - Model access and routing policy        (parallels 02-01 model RBAC)
--        - User-attributed inference consumption   (parallels 05-01 tagging)
--        - Team-level shared budgets                (parallels 05-02 budget)
--        - Per-user quota enforcement                (parallels 05-02 quota)
--        - Cross-application usage history           (this section)
--      A shared resource budget remains a pooled, periodically evaluated team
--      control regardless of entry point. A per-user quota remains the only
--      control in this lab with built-in user blocking. AI Gateway does not
--      make these two controls identical - it only gives them one more shared
--      resource type to scope against (ADD_SHARED_RESOURCE('AI GATEWAY')).
--      AI Gateway is currently documented as a Preview feature open to all
--      accounts; validate current status before using this material externally.
-- ============================================================================

-- ============================================================================
-- 5.22 OPTIONAL - BEYOND AGENTS AND AI FUNCTIONS: per-service views vs the whole
--      05-01..05-04 focus on Cortex Agents and AI Functions. The rest of Cortex
--      AI does not need extra budgets to be visible. Two lenses:
--
--      (a) DETAIL for one service -> each service has its own usage view, with
--          its own credit / user / tag columns (checked against the ACCOUNT_USAGE
--          reference; all readable with SNOWFLAKE.USAGE_VIEWER):
--        | Service                 | ACCOUNT_USAGE view                          | Credits column | User          | USER_TAGS |
--        |-------------------------|---------------------------------------------|----------------|---------------|-----------|
--        | Cortex Agents           | CORTEX_AGENT_USAGE_HISTORY                  | TOKEN_CREDITS  | USER_NAME     | yes       |
--        | Snowflake CoWork        | SNOWFLAKE_COWORK_USAGE_HISTORY              | TOKEN_CREDITS  | USER_NAME     | yes       |
--        | Cortex Analyst          | CORTEX_ANALYST_USAGE_HISTORY                | CREDITS        | USERNAME      | no        |
--        | AI Functions            | CORTEX_AI_FUNCTIONS_USAGE_HISTORY           | CREDITS        | USER_ID (*1)  | no        |
--        | Cortex REST API         | CORTEX_REST_API_USAGE_HISTORY               | - (TOKENS only, *2) | USER_ID  | no        |
--        | CoCo CLI                | CORTEX_CODE_CLI_USAGE_HISTORY               | TOKEN_CREDITS  | USER_NAME     | yes       |
--        | CoCo Snowsight          | CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY         | TOKEN_CREDITS  | USER_NAME     | yes       |
--        | CoCo Desktop            | CORTEX_CODE_DESKTOP_USAGE_HISTORY           | TOKEN_CREDITS  | USER_NAME     | yes       |
--        | Cortex Search           | CORTEX_SEARCH_DAILY_USAGE_HISTORY (*3)      | CREDITS        | -             | no        |
--        | Document Processing     | CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY    | CREDITS_USED   | - (QUERY_ID)  | no        |
--        | AI Guardrails           | CORTEX_AI_GUARDRAILS_USAGE_HISTORY          | TOKEN_CREDITS  | USER_NAME     | yes       |
--        | Fine-tuning             | CORTEX_FINE_TUNING_USAGE_HISTORY            | TOKEN_CREDITS  | -             | no        |
--        | Provisioned Throughput  | CORTEX_PROVISIONED_THROUGHPUT_USAGE_HISTORY | PTU_CREDITS    | -             | no        |
--        | AI Gateway              | AI_GATEWAY_USAGE_HISTORY                    | CREDITS        | USER_ID       | no        |
--        | Document AI (legacy)    | DOCUMENT_AI_USAGE_HISTORY                   | CREDITS_USED   | - (QUERY_ID)  | no        |
--        (*1) resolve the name via QUERY_HISTORY.QUERY_ID (see 5.16).
--        (*2) the REST API view has no credits column; price TOKENS with the
--             Service Consumption Table, or use METERING_HISTORY below.
--             Requests routed through AI Gateway also appear in the REST API
--             view with the same REQUEST_ID - they are removed from the REST
--             rows before the UNION so they are counted once (as AI Gateway).
--        (*3) daily total; SERVING_ and BATCH_QUERY_USAGE_HISTORY are its detail.
--        Not summed below to avoid double counting:
--          SNOWFLAKE_COCO_USAGE_HISTORY  = the three CoCo views in one (INTERFACE column)
--          CORTEX_FUNCTIONS_(QUERY_)USAGE_HISTORY, CORTEX_AISQL_USAGE_HISTORY
--                                        = older views superseded by CORTEX_AI_FUNCTIONS_*
--      (b) WHOLE PICTURE -> METERING_HISTORY: one row per service type per hour,
--          the same numbers billing uses. No user / tag detail.
--
--      Attribution notes: CoCo overwrites the session QUERY_TAG, so only USER
--      tags attribute CoCo spend; and the entry point decides - an agent called
--      from a CoWork chat is billed to CoWork, not to Cortex Agents.
-- ============================================================================
USE ROLE AGOV_AUDITOR;
USE WAREHOUSE AGOV_WH;

-- (a-1) Every per-service view side by side, month to date. Each row reads a
--       different view with its own credit column - compare with (b) below.
--       Services you don't use return 0 rows / NULL credits.
WITH s AS (SELECT DATE_TRUNC('MONTH', CURRENT_DATE())::TIMESTAMP_LTZ AS t0)
SELECT 'Cortex Agents' AS service, 'CORTEX_AGENT_USAGE_HISTORY' AS source_view,
       SUM(token_credits) AS credits, COUNT(*) AS n_rows
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY, s WHERE start_time >= s.t0
UNION ALL SELECT 'Snowflake CoWork', 'SNOWFLAKE_COWORK_USAGE_HISTORY', SUM(token_credits), COUNT(*)
FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COWORK_USAGE_HISTORY, s WHERE start_time >= s.t0
UNION ALL SELECT 'Cortex Analyst', 'CORTEX_ANALYST_USAGE_HISTORY', SUM(credits), COUNT(*)
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY, s WHERE start_time >= s.t0
UNION ALL SELECT 'AI Functions', 'CORTEX_AI_FUNCTIONS_USAGE_HISTORY', SUM(credits), COUNT(*)
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY, s WHERE start_time >= s.t0
-- REST API: drop requests that AI Gateway already recorded (same REQUEST_ID).
-- Gateway rows win because they carry CREDITS; REST rows only have TOKENS.
UNION ALL SELECT 'Cortex REST API', 'CORTEX_REST_API_USAGE_HISTORY (tokens only, minus AI Gateway)', NULL, COUNT(*)
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_REST_API_USAGE_HISTORY r, s
WHERE r.start_time >= s.t0
  AND NOT EXISTS (SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.AI_GATEWAY_USAGE_HISTORY g
                  WHERE g.request_id = r.request_id)
UNION ALL SELECT 'CoCo CLI', 'CORTEX_CODE_CLI_USAGE_HISTORY', SUM(token_credits), COUNT(*)
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY, s WHERE usage_time >= s.t0
UNION ALL SELECT 'CoCo Snowsight', 'CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY', SUM(token_credits), COUNT(*)
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY, s WHERE usage_time >= s.t0
UNION ALL SELECT 'CoCo Desktop', 'CORTEX_CODE_DESKTOP_USAGE_HISTORY', SUM(token_credits), COUNT(*)
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_DESKTOP_USAGE_HISTORY, s WHERE usage_time >= s.t0
UNION ALL SELECT 'Cortex Search', 'CORTEX_SEARCH_DAILY_USAGE_HISTORY', SUM(credits), COUNT(*)
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY, s WHERE usage_date >= s.t0::DATE
UNION ALL SELECT 'Document Processing', 'CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY', SUM(credits_used), COUNT(*)
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY, s WHERE start_time >= s.t0
UNION ALL SELECT 'AI Guardrails', 'CORTEX_AI_GUARDRAILS_USAGE_HISTORY', SUM(token_credits), COUNT(*)
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_GUARDRAILS_USAGE_HISTORY, s WHERE usage_time >= s.t0
UNION ALL SELECT 'Fine-tuning', 'CORTEX_FINE_TUNING_USAGE_HISTORY', SUM(token_credits), COUNT(*)
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FINE_TUNING_USAGE_HISTORY, s WHERE start_time >= s.t0
UNION ALL SELECT 'Provisioned Throughput', 'CORTEX_PROVISIONED_THROUGHPUT_USAGE_HISTORY', SUM(ptu_credits), COUNT(*)
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_PROVISIONED_THROUGHPUT_USAGE_HISTORY, s WHERE interval_start_time >= s.t0
UNION ALL SELECT 'AI Gateway', 'AI_GATEWAY_USAGE_HISTORY', SUM(credits), COUNT(*)
FROM SNOWFLAKE.ACCOUNT_USAGE.AI_GATEWAY_USAGE_HISTORY, s WHERE start_time >= s.t0
ORDER BY credits DESC NULLS LAST;

-- (a-2) Detail example: CoCo + CoWork by cost center from request-level USER_TAGS.
--     Requests made before the 05-01 tag existed stay UNTAGGED (point-in-time).
--     FILTER picks the tag per row without the fan-out of LATERAL FLATTEN.
WITH coco_cowork AS (
    SELECT 'CoCo CLI' AS service, user_tags, token_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY
    WHERE usage_time >= DATE_TRUNC('MONTH', CURRENT_DATE())
    UNION ALL
    SELECT 'CoCo Desktop', user_tags, token_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_DESKTOP_USAGE_HISTORY
    WHERE usage_time >= DATE_TRUNC('MONTH', CURRENT_DATE())
    UNION ALL
    SELECT 'CoCo Snowsight', user_tags, token_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY
    WHERE usage_time >= DATE_TRUNC('MONTH', CURRENT_DATE())
    UNION ALL
    SELECT 'Snowflake CoWork', user_tags, token_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COWORK_USAGE_HISTORY
    WHERE start_time >= DATE_TRUNC('MONTH', CURRENT_DATE())
)
SELECT service,
       COALESCE(FILTER(user_tags, t -> t:tag_name::STRING = 'AI_COST_CENTER')[0]:tag_value::STRING,
                'UNTAGGED') AS cost_center,
       COUNT(*) AS requests,
       ROUND(SUM(token_credits), 4) AS token_credits
FROM coco_cowork
GROUP BY 1, 2
ORDER BY token_credits DESC;

-- (b) Whole picture: every Cortex AI service type this month, from METERING_HISTORY.
--     Matched by pattern so new AI service types show up without editing the list
--     (e.g. CORTEX_AGENTS, AI_FUNCTIONS, CORTEX_SEARCH, SNOWFLAKE_COCO_DESKTOP).
SELECT service_type,
       ROUND(SUM(credits_used), 4) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATE_TRUNC('MONTH', CURRENT_DATE())
  AND (service_type ILIKE 'CORTEX%'
       OR service_type ILIKE 'AI_%'
       OR service_type ILIKE 'SNOWFLAKE_COCO%'
       OR service_type ILIKE '%INTELLIGENCE%'
       OR service_type ILIKE '%COWORK%')
GROUP BY 1
ORDER BY credits DESC;

-- Same source, daily trend - the chart-ready "all of Cortex AI" view.
SELECT DATE_TRUNC('DAY', start_time)::DATE AS usage_day,
       service_type,
       ROUND(SUM(credits_used), 4) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD('DAY', -30, CURRENT_DATE())
  AND (service_type ILIKE 'CORTEX%'
       OR service_type ILIKE 'AI_%'
       OR service_type ILIKE 'SNOWFLAKE_COCO%'
       OR service_type ILIKE '%INTELLIGENCE%'
       OR service_type ILIKE '%COWORK%')
GROUP BY 1, 2
ORDER BY 1, 3 DESC;
