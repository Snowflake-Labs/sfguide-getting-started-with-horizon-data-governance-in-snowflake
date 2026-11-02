/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale
Part:         PART 3 - Data Movement Governance
File:         03-01 - Data Movement Policy: approved-agent allow-list + Snowsight download control
Story:        Parts 1-2 decide WHAT a user or agent may see. Part 3 decides how much of it may
              LEAVE, and through which channel:
                (a) AGENT_ACCESS - only an approved agent may read the protected data. An
                    identical "shadow" agent (same model, tool, semantic view, and grants) is
                    hard-blocked.
                (b) UI_DOWNLOAD  - the Snowsight Download button is disabled for everyone
                    except the data custodian (AGOV_GOVERNOR).
                (c) AGENT_ACCESS alert - an approved-agent statement that moves more than
                    100 rows is allowed but recorded.
Design:       Tag-based attachment only (no account-level policy). A dedicated
              DATA_MOVEMENT_DOMAIN tag keeps movement control separate from
              DATA_CLASSIFICATION (masking) and CONSENT_ENFORCEMENT (row access).
              Part 3 builds its OWN data path from base tables and views:
                BRONZE.CUSTOMER_ORDERS -> SILVER.CUSTOMER_ORDERS_V -> GOLD.ORDER_ANALYTICS_SV
              It does not use the SILVER dynamic table.
Before:       Part 2 complete, including the human-run 02-04.6 RSS cleanup and a fresh
              Snowflake session and CoCo chat.
Execution:    03-01.0 to 03-01.7 run as a batch. 03-01.8 (download button) is a manual
              Snowsight check. 03-01.9 calls the agent in batch but its outcome needs
              inspection. 03-01.10 reads ACCOUNT_USAGE and is only meaningful up to
              3 hours later.
Rerun:        This script never detaches the policy. On a rerun the policy from the
              previous run is still attached, so the 03-01.2 baseline is NOT a no-policy
              baseline. For a clean first-run baseline, run 99-Teardown.sql, then 00-Setup
              through Part 2 again.
Docs:         https://docs.snowflake.com/en/user-guide/data-movement-policies
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
****************************************************************************************************/

-- ============================================================================
-- 03-01.0  PRIVILEGES  (ACCOUNTADMIN)
--      AGOV_GOVERNOR owns GOVERNANCE, so it can create rules and policies there.
--      Attaching a policy to a tag needs APPLY DATA MOVEMENT POLICY on the account.
-- ============================================================================
-- ACCOUNTADMIN required: SECURITYADMIN gets Insufficient privileges on this
-- account privilege (rehearsal 2026-11-02)
USE ROLE ACCOUNTADMIN;
GRANT APPLY DATA MOVEMENT POLICY ON ACCOUNT TO ROLE AGOV_GOVERNOR;

-- ============================================================================
-- 03-01.1  PART 3 DATA PATH (base table -> view -> semantic view)
--      Published by the CI/CD identity, like every other medallion object.
--      Order-level data only; every column is DATA_CLASSIFICATION = INTERNAL.
-- ============================================================================
USE ROLE AGOV_PIPELINE_SERVICE_ROLE;
USE WAREHOUSE AGOV_WH;
USE SECONDARY ROLES NONE;

CREATE OR REPLACE VIEW AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDERS_V
  COMMENT = 'Part 3: order-level view over BRONZE.CUSTOMER_ORDERS (DMP-covered path; not the dynamic table)'
AS
SELECT ORDER_ID, CUSTOMER_ID, ORDER_TS, ORDER_CURRENCY, ORDER_AMOUNT, ORDER_TAX, ORDER_TOTAL
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER_ORDERS;

CREATE OR REPLACE SEMANTIC VIEW AGENTIC_GOV_DB.GOLD.ORDER_ANALYTICS_SV
  TABLES (
    orders AS AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDERS_V PRIMARY KEY (ORDER_ID)
      WITH SYNONYMS ('orders','sales')
  )
  FACTS (
    orders.order_total_fact AS ORDER_TOTAL
  )
  DIMENSIONS (
    orders.order_id   AS ORDER_ID,
    orders.order_date AS ORDER_TS       WITH SYNONYMS = ('order date','date'),
    orders.currency   AS ORDER_CURRENCY WITH SYNONYMS = ('currency')
  )
  METRICS (
    orders.total_revenue       AS SUM(orders.order_total_fact) WITH SYNONYMS = ('revenue','total sales'),
    orders.total_orders        AS COUNT(orders.order_id)       WITH SYNONYMS = ('order count'),
    orders.average_order_value AS AVG(orders.order_total_fact) WITH SYNONYMS = ('AOV')
  )
  COMMENT = 'Part 3: order analytics over SILVER.CUSTOMER_ORDERS_V (DMP-covered)';

GRANT SELECT ON VIEW AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDERS_V TO ROLE AGOV_GOVERNOR;
GRANT SELECT ON VIEW AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDERS_V TO ROLE AGOV_ANALYST;
GRANT SELECT ON SEMANTIC VIEW AGENTIC_GOV_DB.GOLD.ORDER_ANALYTICS_SV TO ROLE AGOV_GOVERNOR;
GRANT SELECT ON SEMANTIC VIEW AGENTIC_GOV_DB.GOLD.ORDER_ANALYTICS_SV TO ROLE AGOV_ANALYST;


-- 03-01.1 CHECK A: the view returns data (still as AGOV_PIPELINE_SERVICE_ROLE)
SELECT COUNT(*) AS row_cnt, COUNT(DISTINCT ORDER_CURRENCY) AS currencies,
       SUM(ORDER_TOTAL) AS total_revenue
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDERS_V;
-- Expected: 30000 | 1 | 743292.7625

-- 03-01.1 CHECK B: semantic view structure
DESCRIBE SEMANTIC VIEW AGENTIC_GOV_DB.GOLD.ORDER_ANALYTICS_SV;
-- Expected: 1 table, 1 fact, 3 dimensions, 3 metrics

-- 03-01.1 CHECK C: grants reached both consumer roles
SHOW GRANTS ON VIEW AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDERS_V;
SHOW GRANTS ON SEMANTIC VIEW AGENTIC_GOV_DB.GOLD.ORDER_ANALYTICS_SV;
-- Expected: SELECT for AGOV_GOVERNOR and AGOV_ANALYST

-- ============================================================================
-- 03-01.2  TWO AGENTS: approved and shadow (identical except for the name)
--      Any later difference in outcome is caused by DMP alone.
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
USE SCHEMA AGENTIC_GOV_DB.AGENTS;

CREATE OR REPLACE AGENT AGENTIC_GOV_DB.AGENTS.ORDER_ANALYTICS_AGENT
  COMMENT = 'Part 3: APPROVED order-analytics agent (on the data-movement allow-list)'
  PROFILE = '{"display_name": "Order Analytics Agent (approved)", "color": "blue"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: claude-sonnet-5
  instructions:
    response: >
      Report the Order Analytics tool's results exactly as returned, including any error
      message. Governance policies decide what you may receive; do not second-guess them.
    orchestration: >
      For any order, revenue, or currency question, always call the Order Analytics tool.
    sample_questions:
      - question: "What is total revenue and order count by currency?"
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "order_analytics"
        description: "Order counts, revenue, and average order value by currency and date."
  tool_resources:
    order_analytics:
      semantic_view: "AGENTIC_GOV_DB.GOLD.ORDER_ANALYTICS_SV"
      execution_environment:
        type: "warehouse"
        warehouse: "AGOV_WH"
  $$;

CREATE OR REPLACE AGENT AGENTIC_GOV_DB.AGENTS.SHADOW_ORDER_ANALYTICS_AGENT
  COMMENT = 'Part 3: SHADOW agent - identical spec, NOT on the data-movement allow-list'
  PROFILE = '{"display_name": "Order Analytics Agent (shadow)", "color": "red"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: claude-sonnet-5
  instructions:
    response: >
      Report the Order Analytics tool's results exactly as returned, including any error
      message. Governance policies decide what you may receive; do not second-guess them.
    orchestration: >
      For any order, revenue, or currency question, always call the Order Analytics tool.
    sample_questions:
      - question: "What is total revenue and order count by currency?"
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "order_analytics"
        description: "Order counts, revenue, and average order value by currency and date."
  tool_resources:
    order_analytics:
      semantic_view: "AGENTIC_GOV_DB.GOLD.ORDER_ANALYTICS_SV"
      execution_environment:
        type: "warehouse"
        warehouse: "AGOV_WH"
  $$;

GRANT USAGE ON AGENT AGENTIC_GOV_DB.AGENTS.ORDER_ANALYTICS_AGENT        TO ROLE AGOV_ANALYST;
GRANT USAGE ON AGENT AGENTIC_GOV_DB.AGENTS.SHADOW_ORDER_ANALYTICS_AGENT TO ROLE AGOV_ANALYST;

-- Baseline: before any DMP exists, BOTH agents answer.
USE ROLE AGOV_ANALYST;
USE WAREHOUSE AGOV_WH;
USE SECONDARY ROLES NONE;

WITH r AS (
    SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
        'AGENTIC_GOV_DB.AGENTS.SHADOW_ORDER_ANALYTICS_AGENT',
        $${"messages":[{"role":"user","content":[{"type":"text","text":"What is total revenue and order count by currency?"}]}]}$$,
        TRUE) AS raw
)
SELECT '03-01.2 baseline: SHADOW agent, no DMP' AS scenario,
       LISTAGG(CASE WHEN f.value:type::STRING = 'tool_result'
                    THEN TO_JSON(f.value:tool_result:content) END, '\n') AS tool_results,
       MAX(CASE WHEN f.value:type::STRING = 'text' THEN TRIM(f.value:text::STRING) END) AS agent_answer_not_authoritative
FROM r, LATERAL FLATTEN(input => PARSE_JSON(r.raw):content, OUTER => TRUE) f;
-- Expected (first run): USD | 30000 orders | 743292.7625 revenue. Without DMP the shadow
-- agent works. On a RE-RUN the policy from the previous run is still attached, so this
-- baseline already shows "Data movement policy triggered". That is expected and is not a
-- no-policy baseline (see Rerun in the header).


-- 03-01.2 CHECK A: both agents exist
SHOW AGENTS IN SCHEMA AGENTIC_GOV_DB.AGENTS;
-- Expected: ORDER_ANALYTICS_AGENT, CUSTOMER_INSIGHTS_AGENT and SHADOW_ORDER_ANALYTICS_AGENT

-- 03-01.2 CHECK B: the specs match (point at the same semantic view)
DESCRIBE AGENT AGENTIC_GOV_DB.AGENTS.ORDER_ANALYTICS_AGENT;
DESCRIBE AGENT AGENTIC_GOV_DB.AGENTS.SHADOW_ORDER_ANALYTICS_AGENT;
-- Expected: same agent_spec except name, comment and profile

-- 03-01.2 CHECK C: the analyst can use both
SHOW GRANTS ON AGENT AGENTIC_GOV_DB.AGENTS.ORDER_ANALYTICS_AGENT;
SHOW GRANTS ON AGENT AGENTIC_GOV_DB.AGENTS.SHADOW_ORDER_ANALYTICS_AGENT;
-- Expected: USAGE for AGOV_ANALYST on each



-- ============================================================================
-- 03-01.3  MOVEMENT-DOMAIN TAG (propagating) and placement
--      DMP requires PROPAGATE = ON_DEPENDENCY_AND_DATA_MOVEMENT on the tag.
--      Tag the base tables and the views explicitly. The SILVER dynamic table also
--      inherits the tag through propagation, but it is not enforced there.
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
CREATE TAG IF NOT EXISTS AGENTIC_GOV_DB.GOVERNANCE.DATA_MOVEMENT_DOMAIN
    ALLOWED_VALUES 'CUSTOMER_DATA'
    PROPAGATE = ON_DEPENDENCY_AND_DATA_MOVEMENT
    COMMENT = 'Data movement domain. Drives data movement policies (exfiltration control), independent of classification and consent.';

ALTER TABLE AGENTIC_GOV_DB.BRONZE.CUSTOMER
    SET TAG AGENTIC_GOV_DB.GOVERNANCE.DATA_MOVEMENT_DOMAIN = 'CUSTOMER_DATA';
ALTER TABLE AGENTIC_GOV_DB.BRONZE.CUSTOMER_ORDERS
    SET TAG AGENTIC_GOV_DB.GOVERNANCE.DATA_MOVEMENT_DOMAIN = 'CUSTOMER_DATA';
ALTER VIEW AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDERS_V
    SET TAG AGENTIC_GOV_DB.GOVERNANCE.DATA_MOVEMENT_DOMAIN = 'CUSTOMER_DATA';
ALTER VIEW AGENTIC_GOV_DB.SILVER.CUSTOMER_CONTACT_ACTIVATION_V
    SET TAG AGENTIC_GOV_DB.GOVERNANCE.DATA_MOVEMENT_DOMAIN = 'CUSTOMER_DATA';

SELECT 'BRONZE.CUSTOMER' AS object_name, SYSTEM$GET_TAG('AGENTIC_GOV_DB.GOVERNANCE.DATA_MOVEMENT_DOMAIN', 'AGENTIC_GOV_DB.BRONZE.CUSTOMER', 'TABLE') AS movement_domain
UNION ALL SELECT 'BRONZE.CUSTOMER_ORDERS', SYSTEM$GET_TAG('AGENTIC_GOV_DB.GOVERNANCE.DATA_MOVEMENT_DOMAIN', 'AGENTIC_GOV_DB.BRONZE.CUSTOMER_ORDERS', 'TABLE')
UNION ALL SELECT 'SILVER.CUSTOMER_ORDERS_V', SYSTEM$GET_TAG('AGENTIC_GOV_DB.GOVERNANCE.DATA_MOVEMENT_DOMAIN', 'AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDERS_V', 'TABLE')
UNION ALL SELECT 'SILVER.CUSTOMER_CONTACT_ACTIVATION_V', SYSTEM$GET_TAG('AGENTIC_GOV_DB.GOVERNANCE.DATA_MOVEMENT_DOMAIN', 'AGENTIC_GOV_DB.SILVER.CUSTOMER_CONTACT_ACTIVATION_V', 'TABLE');
-- Expected: CUSTOMER_DATA for all four.



-- 03-01.3 CHECK A: tag definition has the propagation mode DMP requires
SHOW TAGS LIKE 'DATA_MOVEMENT_DOMAIN' IN SCHEMA AGENTIC_GOV_DB.GOVERNANCE;
SELECT "name", "allowed_values", "propagate"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
-- Expected: ["CUSTOMER_DATA"] | ON_DEPENDENCY_AND_DATA_MOVEMENT

-- 03-01.3 CHECK B: direct vs propagated placement on the view
SELECT OBJECT_NAME, TAG_NAME, TAG_VALUE, APPLY_METHOD, LEVEL
FROM TABLE(AGENTIC_GOV_DB.INFORMATION_SCHEMA.TAG_REFERENCES(
       'AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDERS_V', 'table'))
WHERE TAG_NAME = 'DATA_MOVEMENT_DOMAIN';
-- Expected: CUSTOMER_DATA, APPLY_METHOD = MANUAL




-- ============================================================================
-- 03-01.4  RULES  (one rule = one movement type; MAX_ROWS: NULL = no limit,
--          0 = block, N = at most N rows per statement)
--      Re-runnable pattern: CREATE ... IF NOT EXISTS, then ALTER ... SET MAX_ROWS.
--      CREATE OR REPLACE fails once a policy references the rule (error 503508);
--      ALTER works while the rule is attached.
--      Rule-body notes (tested): compare UPPER(AGENT_NAME) directly - wrapping it in
--      REPLACE(...) broke every comparison; ILIKE is rejected in a rule body.
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
USE SCHEMA AGENTIC_GOV_DB.GOVERNANCE;

-- (a) Approved-agent allow-list: hard block for every other agent or MCP-style client.
--     AGENT_NAME is the fully qualified agent name; match the full FQN so a same-named
--     agent in another schema is not approved.
CREATE DATA MOVEMENT RULE IF NOT EXISTS AGENTIC_GOV_DB.GOVERNANCE.DMR_AGENT_ALLOWLIST
  TYPE = 'AGENT_ACCESS'
  MAX_ROWS AS () RETURNS INTEGER -> (0)
  COMMENT = 'Only approved agents may read CUSTOMER_DATA; every other agent is blocked.';
ALTER DATA MOVEMENT RULE AGENTIC_GOV_DB.GOVERNANCE.DMR_AGENT_ALLOWLIST
  SET MAX_ROWS AS () RETURNS INTEGER
  -> (
    CASE
      WHEN UPPER(SYS_CONTEXT('SNOWFLAKE$DATA_MOVEMENT', 'AGENT_NAME')) IN (
             'AGENTIC_GOV_DB.AGENTS.ORDER_ANALYTICS_AGENT',
             'AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT'   -- Part 2 agent
           ) THEN NULL
      ELSE 0
    END
  );

-- (b) Approved-agent volume: allow, but record any agent statement moving > 100 rows.
CREATE DATA MOVEMENT RULE IF NOT EXISTS AGENTIC_GOV_DB.GOVERNANCE.DMR_AGENT_VOLUME_ALERT
  TYPE = 'AGENT_ACCESS'
  MAX_ROWS AS () RETURNS INTEGER -> (100)
  COMMENT = 'Alert when an agent moves more than 100 rows of CUSTOMER_DATA in one statement.';
ALTER DATA MOVEMENT RULE AGENTIC_GOV_DB.GOVERNANCE.DMR_AGENT_VOLUME_ALERT
  SET MAX_ROWS AS () RETURNS INTEGER -> (100);

-- (c) Snowsight Download button: custodian only. UI_DOWNLOAD is enforce-only.
--     Covers the Workspaces results pane, notebook cell results in Workspaces, and
--     Query History; not every surface (e.g. Streamlit, Export as HTML, CoWork).
CREATE DATA MOVEMENT RULE IF NOT EXISTS AGENTIC_GOV_DB.GOVERNANCE.DMR_UI_DOWNLOAD_CUSTODIAN_ONLY
  TYPE = 'UI_DOWNLOAD'
  MAX_ROWS AS () RETURNS INTEGER -> (0)
  COMMENT = 'Disable the Snowsight Download button on CUSTOMER_DATA for every role except AGOV_GOVERNOR.';
ALTER DATA MOVEMENT RULE AGENTIC_GOV_DB.GOVERNANCE.DMR_UI_DOWNLOAD_CUSTODIAN_ONLY
  SET MAX_ROWS AS () RETURNS INTEGER
  -> (CASE WHEN SYS_CONTEXT('SNOWFLAKE$SESSION', 'ROLE') = 'AGOV_GOVERNOR' THEN NULL ELSE 0 END);

SHOW DATA MOVEMENT RULES IN SCHEMA AGENTIC_GOV_DB.GOVERNANCE;


-- 03-01.4 CHECK A: each rule's type and current body
DESCRIBE DATA MOVEMENT RULE AGENTIC_GOV_DB.GOVERNANCE.DMR_AGENT_ALLOWLIST;
DESCRIBE DATA MOVEMENT RULE AGENTIC_GOV_DB.GOVERNANCE.DMR_AGENT_VOLUME_ALERT;
DESCRIBE DATA MOVEMENT RULE AGENTIC_GOV_DB.GOVERNANCE.DMR_UI_DOWNLOAD_CUSTODIAN_ONLY;
-- Expected: AGENT_ACCESS / AGENT_ACCESS / UI_DOWNLOAD. The body shows the ALTERed CASE, not (0).

-- 03-01.4 CHECK B: each rule exists with the intended movement type
SHOW DATA MOVEMENT RULES IN SCHEMA AGENTIC_GOV_DB.GOVERNANCE
->> SELECT 'dmp_rule_types' AS check_name,
           COUNT_IF("name" = 'DMR_AGENT_ALLOWLIST'            AND "type" = 'AGENT_ACCESS') = 1
       AND COUNT_IF("name" = 'DMR_AGENT_VOLUME_ALERT'         AND "type" = 'AGENT_ACCESS') = 1
       AND COUNT_IF("name" = 'DMR_UI_DOWNLOAD_CUSTODIAN_ONLY' AND "type" = 'UI_DOWNLOAD')  = 1 AS passed
    FROM $1;
-- Expected: TRUE

-- 03-01.4 CHECK C: the allow-list names the approved agent and not the shadow agent
SELECT 'dmp_allowlist_approved_only' AS check_name,
       CONTAINS(d, '''AGENTIC_GOV_DB.AGENTS.ORDER_ANALYTICS_AGENT''')
       AND NOT CONTAINS(d, 'SHADOW_ORDER_ANALYTICS_AGENT')
       AND CONTAINS(d, 'ELSE 0') AS passed
FROM (SELECT GET_DDL('DATA_MOVEMENT_RULE', 'AGENTIC_GOV_DB.GOVERNANCE.DMR_AGENT_ALLOWLIST') AS d);
-- Expected: TRUE





-- ============================================================================
-- 03-01.5  POLICY + TAG ATTACHMENT  (re-runnable)
-- ============================================================================
CREATE DATA MOVEMENT POLICY IF NOT EXISTS AGENTIC_GOV_DB.GOVERNANCE.CUSTOMER_DATA_DMP
  ENFORCE_RULES = (DMR_AGENT_ALLOWLIST, DMR_UI_DOWNLOAD_CUSTODIAN_ONLY)
  ALERT_RULES   = (DMR_AGENT_VOLUME_ALERT)
  COMMENT = 'CUSTOMER_DATA exfiltration guardrails: approved agents only, custodian-only download, alert on agent volume.';
ALTER DATA MOVEMENT POLICY AGENTIC_GOV_DB.GOVERNANCE.CUSTOMER_DATA_DMP
  SET ENFORCE_RULES = (DMR_AGENT_ALLOWLIST, DMR_UI_DOWNLOAD_CUSTODIAN_ONLY);
ALTER DATA MOVEMENT POLICY AGENTIC_GOV_DB.GOVERNANCE.CUSTOMER_DATA_DMP
  SET ALERT_RULES = (DMR_AGENT_VOLUME_ALERT);

-- FORCE replaces an existing attachment, so the statement is safe to re-run.
-- (Do not wrap DMP DDL in EXECUTE IMMEDIATE: the scripting parser rejected it in testing.)
ALTER TAG AGENTIC_GOV_DB.GOVERNANCE.DATA_MOVEMENT_DOMAIN
  SET DATA MOVEMENT POLICY AGENTIC_GOV_DB.GOVERNANCE.CUSTOMER_DATA_DMP FORCE;


-- 03-01.5 CHECK A: enforce and alert lists are correct
DESCRIBE DATA MOVEMENT POLICY AGENTIC_GOV_DB.GOVERNANCE.CUSTOMER_DATA_DMP;
-- Expected: ENFORCE = DMR_AGENT_ALLOWLIST, DMR_UI_DOWNLOAD_CUSTODIAN_ONLY | ALERT = DMR_AGENT_VOLUME_ALERT

SELECT 'dmp_policy_rule_lists' AS check_name,
       REGEXP_LIKE(d, '.*ENFORCE_RULES=\\(DMR_AGENT_ALLOWLIST, DMR_UI_DOWNLOAD_CUSTODIAN_ONLY\\).*', 's')
       AND REGEXP_LIKE(d, '.*ALERT_RULES=\\(DMR_AGENT_VOLUME_ALERT\\).*', 's') AS passed
FROM (SELECT GET_DDL('DATA_MOVEMENT_POLICY', 'AGENTIC_GOV_DB.GOVERNANCE.CUSTOMER_DATA_DMP') AS d);
-- Expected: TRUE

-- 03-01.5 CHECK B: the policy is attached to the tag
--      SHOW DATA MOVEMENT POLICIES and GET_DDL prove the policy EXISTS, not that it is
--      attached. The POLICY_REFERENCES reference does not document DMP attachment
--      inspection, so this exercise uses behaviour rather than an unverified metadata
--      assertion. In 03-01.6 compare the approved agent, blocked shadow agent, and
--      successful direct SQL against the no-policy baseline. Inspect the tool error
--      and its Query History entry together, not just the agent's answer.





-- ============================================================================
-- THE ACTUAL TEST STARTS NOW
-- ============================================================================

-- ============================================================================
-- 03-01.6  PROOF - AGENT ALLOW-LIST  (same analyst, same question, two agents)
--      Judge by tool results and Query History, never by the agent's wording.
-- ============================================================================
USE ROLE AGOV_ANALYST;
USE WAREHOUSE AGOV_WH;
USE SECONDARY ROLES NONE;

WITH r AS (
    SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
        'AGENTIC_GOV_DB.AGENTS.ORDER_ANALYTICS_AGENT',
        $${"messages":[{"role":"user","content":[{"type":"text","text":"What is total revenue and order count by currency?"}]}]}$$,
        TRUE) AS raw
)
SELECT '03-01.6 A1: APPROVED agent, DMP active' AS scenario,
       LISTAGG(CASE WHEN f.value:type::STRING = 'tool_result'
                    THEN TO_JSON(f.value:tool_result:content) END, '\n') AS tool_results,
       MAX(CASE WHEN f.value:type::STRING = 'text' THEN TRIM(f.value:text::STRING) END) AS agent_answer_not_authoritative
FROM r, LATERAL FLATTEN(input => PARSE_JSON(r.raw):content, OUTER => TRUE) f;
-- Expected: USD | 30000 | 743292.7625 - same as the baseline.

WITH r AS (
    SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
        'AGENTIC_GOV_DB.AGENTS.SHADOW_ORDER_ANALYTICS_AGENT',
        $${"messages":[{"role":"user","content":[{"type":"text","text":"What is total revenue and order count by currency?"}]}]}$$,
        TRUE) AS raw
)
SELECT '03-01.6 A2: SHADOW agent, DMP active' AS scenario,
       LISTAGG(CASE WHEN f.value:type::STRING = 'tool_result'
                    THEN TO_JSON(f.value:tool_result:content) END, '\n') AS tool_results,
       MAX(CASE WHEN f.value:type::STRING = 'text' THEN TRIM(f.value:text::STRING) END) AS agent_answer_not_authoritative
FROM r, LATERAL FLATTEN(input => PARSE_JSON(r.raw):content, OUTER => TRUE) f;
-- Expected: the tool result contains "Data movement policy triggered". No revenue rows.
-- The agent does not refuse; it reports the policy error.

-- Human direct SQL on the same semantic view is a different movement type and is NOT
-- blocked: DMP narrows channels, it does not revoke access.
SELECT '03-01.6 A3: analyst direct SQL (not an agent)' AS scenario, *
FROM SEMANTIC_VIEW(AGENTIC_GOV_DB.GOLD.ORDER_ANALYTICS_SV
    DIMENSIONS orders.currency METRICS orders.total_orders, orders.total_revenue);
-- Expected: USD | 30000 | 743292.7625.

SELECT 'dmp_direct_sql_not_blocked' AS check_name,
       TOTAL_ORDERS = 30000 AND ABS(TOTAL_REVENUE - 743292.7625) < 0.000001 AS passed
FROM SEMANTIC_VIEW(AGENTIC_GOV_DB.GOLD.ORDER_ANALYTICS_SV
    METRICS orders.total_orders, orders.total_revenue);
-- Expected: TRUE




-- ============================================================================
-- 03-01.7  EVIDENCE - what actually executed (near-real-time Query History)
-- ============================================================================
-- SYSADMIN owns AGOV_WH (MONITOR). Query history by user is scoped to your user.
USE ROLE SYSADMIN;
SELECT START_TIME, ROLE_NAME, AGENT_TYPE, EXECUTION_STATUS, ERROR_CODE,
       LEFT(ERROR_MESSAGE, 200) AS error_message, LEFT(QUERY_TEXT, 120) AS sql_text
FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER(
        USER_NAME => CURRENT_USER(), RESULT_LIMIT => 300))
WHERE AGENT_TYPE IS NOT NULL
  AND START_TIME >= DATEADD('minute', -15, CURRENT_TIMESTAMP())
ORDER BY START_TIME DESC
LIMIT 20;
-- Expected: approved agent SQL SUCCESS; shadow agent SQL FAILED_WITH_ERROR, ERROR_CODE 1003,
-- "Data movement policy triggered". Agents also retry, so unrelated compilation errors
-- (for example 2003 or 904) can appear; only 1003 with this message is the policy block.

-- ============================================================================
-- 03-01.8  MANUAL: SNOWSIGHT DOWNLOAD BUTTON (UI_DOWNLOAD, analyst vs governor)
--      Run in a Snowsight Workspaces SQL file, not through the CLI. The query runs
--      for both roles. Only the Download button on the results pane differs.
--      UI_DOWNLOAD is evaluated after the query finishes and disables the button.
--      It writes no row to DATA_MOVEMENT_VIOLATIONS, so the button state is the
--      evidence. No file download is required.
-- ============================================================================
-- Step 1: analyst
USE ROLE AGOV_ANALYST;
USE WAREHOUSE AGOV_WH;
USE SECONDARY ROLES NONE;
SELECT '03-01.8 download: AGOV_ANALYST' AS scenario, ORDER_ID, ORDER_TS, ORDER_CURRENCY, ORDER_TOTAL
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDERS_V
ORDER BY TO_NUMBER(ORDER_ID)
LIMIT 20;
-- Expected: 20 rows return. Download button on the results pane is DISABLED.

-- Step 2: governor (custodian), same query
USE ROLE AGOV_GOVERNOR;
USE SECONDARY ROLES NONE;
SELECT '03-01.8 download: AGOV_GOVERNOR' AS scenario, ORDER_ID, ORDER_TS, ORDER_CURRENCY, ORDER_TOTAL
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDERS_V
ORDER BY TO_NUMBER(ORDER_ID)
LIMIT 20;
-- Expected: the same 20 rows. Download button is ENABLED.
-- The same rule also covers the result download in Query History. Streamlit, Export
-- as HTML, and CoWork are outside UI_DOWNLOAD coverage.

-- ============================================================================
-- 03-01.9  CONTROLLED VOLUME ALERT (approved agent, more than 100 rows)
--      DMR_AGENT_VOLUME_ALERT is an alert rule: the statement is allowed and recorded.
--      Row thresholds are evaluated per statement. The prompt asks for exactly 101
--      individual order_id rows. The model may still add a lower LIMIT, so judge by the
--      rows the tool's SQL actually produced, never by the agent's text.
-- ============================================================================
USE ROLE AGOV_ANALYST;
USE WAREHOUSE AGOV_WH;
USE SECONDARY ROLES NONE;

WITH r AS (
    SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
        'AGENTIC_GOV_DB.AGENTS.ORDER_ANALYTICS_AGENT',
        $${"messages":[{"role":"user","content":[{"type":"text","text":"Using the Order Analytics tool, list exactly 101 individual orders: one row per order_id with its order date and currency, ordered by order_id ascending. Do not aggregate and do not limit the result below 101 rows."}]}]}$$,
        TRUE) AS raw
)
SELECT '03-01.9 volume: APPROVED agent, 101 order_id rows requested' AS scenario,
       ARRAY_AGG(CASE WHEN f.value:type::STRING = 'tool_result'
                      THEN f.value:tool_result END) WITHIN GROUP (ORDER BY f.index) AS tool_results,
       MAX(CASE WHEN f.value:type::STRING = 'text' THEN TRIM(f.value:text::STRING) END) AS agent_answer_not_authoritative
FROM r, LATERAL FLATTEN(input => PARSE_JSON(r.raw):content, OUTER => TRUE) f;
SET dmp_volume_proof_query_id = LAST_QUERY_ID();

-- Inspect the exact statement(s) the tool ran, by query_id from the tool result.
USE ROLE SYSADMIN;
WITH proof AS (
    SELECT TOOL_RESULTS FROM TABLE(RESULT_SCAN($dmp_volume_proof_query_id))
), tool_queries AS (
    SELECT DISTINCT c.value:json:query_id::STRING AS query_id
    FROM proof p, LATERAL FLATTEN(INPUT => p.TOOL_RESULTS) t,
         LATERAL FLATTEN(INPUT => t.value:content) c
    WHERE c.value:json:query_id IS NOT NULL
), history AS (
    SELECT * FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER(
        USER_NAME => CURRENT_USER(), RESULT_LIMIT => 300))
    WHERE START_TIME >= DATEADD('minute', -30, CURRENT_TIMESTAMP())
)
SELECT t.query_id, q.ROLE_NAME, q.AGENT_TYPE, q.EXECUTION_STATUS, q.ROWS_PRODUCED,
       LEFT(q.QUERY_TEXT, 200) AS sql_run_by_agent,
       CASE
         WHEN q.QUERY_ID IS NULL           THEN 'NOT PROVEN: query_id not matched in history window'
         WHEN q.EXECUTION_STATUS <> 'SUCCESS' THEN 'NOT PROVEN: tool query did not succeed'
         WHEN q.ROWS_PRODUCED > 100        THEN 'ABOVE THRESHOLD: alert expected in 03-01.10'
         ELSE                                   'NOT PROVEN: 100 rows or fewer'
       END AS volume_status
FROM tool_queries t LEFT JOIN history q ON q.QUERY_ID = t.query_id;
-- Expected: SUCCESS, ROWS_PRODUCED = 101, ABOVE THRESHOLD. Record the query_id for 03-01.10.
-- The model is not guaranteed to return 101 rows. If the status is NOT PROVEN (or no
-- query_id is returned), record it as NOT PROVEN, then retry the same approved agent
-- manually in Snowflake CoWork as AGOV_ANALYST with:
--   "List order_id, order date and currency for the first 101 orders by order_id.
--    One row per order. Return all 101 rows."
-- and inspect that run's SQL Execution trace and Query History ROWS_PRODUCED.
-- Do not lower the 100-row threshold or loosen the policy to force a result.

-- ============================================================================
-- 03-01.10  POSTURE + DELAYED MONITORING
--      SHOW / DESCRIBE / GET_DDL are immediate. DATA_MOVEMENT_VIOLATIONS and
--      DATA_MOVEMENT_RULE_REFERENCES may lag up to 3 hours. Missing rows inside that
--      window are not a failed control, and a missing violation record does not mean
--      enforcement did not occur. UI_DOWNLOAD is never recorded in
--      DATA_MOVEMENT_VIOLATIONS.
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
SHOW DATA MOVEMENT POLICIES IN SCHEMA AGENTIC_GOV_DB.GOVERNANCE;
SELECT GET_DDL('DATA_MOVEMENT_POLICY', 'AGENTIC_GOV_DB.GOVERNANCE.CUSTOMER_DATA_DMP') AS policy_ddl;

-- Run up to 3 hours after 03-01.6 and 03-01.9 (a new session is fine):
-- SECURITYADMIN holds SNOWFLAKE.GOVERNANCE_VIEWER from 00-Setup.sql 0.7.
USE ROLE SECURITYADMIN;
SELECT TIMESTAMP, QUERY_ID, USER_NAME, MOVEMENT_TYPE, ENFORCED_POLICY, ALERTED_POLICIES, DATA_ENTITIES
FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_MOVEMENT_VIOLATIONS
WHERE USER_NAME = CURRENT_USER()
  AND TIMESTAMP >= DATEADD('day', -1, CURRENT_TIMESTAMP())
  AND ARRAY_TO_STRING(DATA_ENTITIES, ',') ILIKE '%AGENTIC_GOV_DB.%'
  AND (COALESCE(ENFORCED_POLICY, '') ILIKE '%CUSTOMER_DATA_DMP%'
       OR COALESCE(ALERTED_POLICIES, '') ILIKE '%CUSTOMER_DATA_DMP%')
ORDER BY TIMESTAMP DESC;
-- Expected after the lag window:
--   shadow agent statements (03-01.6 A2): MOVEMENT_TYPE = AGENT_ACCESS, ENFORCED_POLICY
--     names DMR_AGENT_ALLOWLIST.
--   the 101-row statement (03-01.9, match its query_id): MOVEMENT_TYPE = AGENT_ACCESS,
--     ENFORCED_POLICY NULL, ALERTED_POLICIES names DMR_AGENT_VOLUME_ALERT.

SELECT POLICY_NAME, RULE_NAME, RULE_MOVEMENT_TYPE, RULE_CATEGORY
FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_MOVEMENT_RULE_REFERENCES
WHERE POLICY_DATABASE = 'AGENTIC_GOV_DB'
  AND POLICY_SCHEMA   = 'GOVERNANCE'
  AND POLICY_NAME     = 'CUSTOMER_DATA_DMP'
ORDER BY RULE_CATEGORY, RULE_NAME;
-- Expected after the lag window:
--   DMR_AGENT_VOLUME_ALERT         | AGENT_ACCESS | ALERT
--   DMR_AGENT_ALLOWLIST            | AGENT_ACCESS | ENFORCE
--   DMR_UI_DOWNLOAD_CUSTODIAN_ONLY | UI_DOWNLOAD  | ENFORCE
