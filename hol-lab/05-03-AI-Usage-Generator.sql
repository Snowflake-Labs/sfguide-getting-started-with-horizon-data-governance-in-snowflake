/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale
Part:         PART 5 - AI Cost Governance
Section:      05-03 - Generate AI Usage on Both Services
Persona:      Demo user (tagged BUSINESS_ANALYTICS in 00-Setup.sql)
Story beat:   05-02 created one budget per AI service, each with a 1-credit limit. This file first
              drives a small, fixed amount of usage on each service so 05-05 can show that each
              budget counted only its own service, then (5.11c) runs a bulk AI_COMPLETE sized to
              push AI Function spend past the 1-credit limit, so the thresholds in 05-04 fire.
              It uses only inline literals - no Part 4 table (AI_REDACT output, FEEDBACK) is
              required, so it keeps working if Part 4 is changed or removed.

              Expected attribution:
                | Call                     | AGOV_AGENT_BUDGET | AGOV_AI_FUNCTION_BUDGET | AGOV_AI_QUOTA |
                |--------------------------|-------------------|-------------------------|---------------|
                | AI_COMPLETE              | -                 | counted                 | counted       |
                | AI_SENTIMENT             | -                 | counted                 | counted       |
                | CUSTOMER_INSIGHTS_AGENT  | counted           | -                       | counted       |
                | PIPELINE_OPS_AGENT       | counted           | -                       | counted       |
              The two budgets never double-count: each sees one service only. The quota sees
              the user's total across both.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
****************************************************************************************************/

-- Cost: 5.11a/5.11b are a handful of short calls (well under 0.01 credit).
-- 5.11c is deliberately larger - about 1.2 credits at the default 100 rows
-- (see the sizing note there). Re-running adds the same amount again.
-- Nothing here returns usage numbers: ACCOUNT_USAGE lags (typically under an
-- hour) and budgets lag up to ~6.5h, so all cost results are read in 05-05.
-- The quota is evaluated within minutes, so the 05-04 daily email is the one
-- signal you can expect during the session.

USE ROLE AGOV_GOVERNOR;   -- holds the Sonnet 5 and Arctic Sentiment model roles (02-01)
USE WAREHOUSE AGOV_WH;
USE SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT;

ALTER SESSION SET QUERY_TAG = 'AGOV_PART5_USAGE_GENERATOR';

-- Inline sample rows. Nothing here depends on Part 1-3 tables.
CREATE OR REPLACE TEMPORARY TABLE AGOV_USAGE_SAMPLES (ID INT, TEXT VARCHAR) AS
SELECT * FROM VALUES
    (1, 'The new dashboard loads quickly and the revenue numbers finally match finance.'),
    (2, 'Support took three days to answer and the export kept timing out.'),
    (3, 'Order history is fine, but the currency filter resets every time I refresh.'),
    (4, 'Great onboarding session, the team explained the masking rules clearly.'),
    (5, 'Nightly load failed twice this week because an upstream column was renamed.');

-- ============================================================================
-- 5.11a AI FUNCTIONS -> AGOV_AI_FUNCTION_BUDGET
-- ============================================================================
SELECT ID,
       AI_COMPLETE(
           'claude-sonnet-5',
           'Summarize this customer comment in at most 10 words: ' || TEXT
       ) AS summary
FROM AGOV_USAGE_SAMPLES;

SELECT ID, AI_SENTIMENT(TEXT) AS sentiment
FROM AGOV_USAGE_SAMPLES;

-- ============================================================================
-- 5.11b CORTEX AGENTS -> AGOV_AGENT_BUDGET
-- ============================================================================
WITH r AS (
    SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
        'AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT',
        $${"messages":[{"role":"user","content":[{"type":"text","text":"How many orders do we have by currency?"}]}]}$$
    ) AS raw
)
SELECT TRIM(f.value:text::STRING) AS customer_insights_answer
FROM r, LATERAL FLATTEN(input => PARSE_JSON(r.raw):content) f
WHERE f.value:type::STRING = 'text';

WITH r AS (
    SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
        'AGENTIC_GOV_DB.AGENTS.PIPELINE_OPS_AGENT',
        $${"messages":[{"role":"user","content":[{"type":"text","text":"What should I check first when a nightly load fails?"}]}]}$$
    ) AS raw
)
SELECT TRIM(f.value:text::STRING) AS pipeline_ops_answer
FROM r, LATERAL FLATTEN(input => PARSE_JSON(r.raw):content) f
WHERE f.value:type::STRING = 'text';

-- ============================================================================
-- 5.11c BULK AI_COMPLETE -> push AI Function spend past the 1-credit limit
--      Sizing (claude-sonnet-5, measured from this lab's own usage history):
--        input  1.2 credits / 1M tokens, output 6 credits / 1M tokens.
--      Each row asks for a long answer capped at max_tokens = 2000, so one row
--      costs at most ~0.012 credits (output dominates; the model may stop
--      earlier, so actual cost can be lower). 100 rows -> up to ~1.2 credits:
--        - past the quota's 10% DAILY threshold (0.1 credit) within ~10 rows
--        - past AGOV_AI_FUNCTION_BUDGET's 1-credit limit
--      Change BULK_ROWS to scale (max 1000). Warehouse time is extra.
--      Only COUNT / total length are returned, not the 100 long answers.
-- ============================================================================
SET BULK_ROWS = 100;

SELECT COUNT(*) AS calls,
       SUM(LENGTH(answer)) AS total_chars
FROM (
    SELECT AI_COMPLETE(
               model => 'claude-sonnet-5',
               prompt => 'Write a detailed, 1500-word operations runbook for recovering a failed '
                         || 'nightly data load, variant #' || seq
                         || '. Use numbered steps and explain each step fully.',
               model_parameters => {'max_tokens': 2000}
           ) AS answer
    FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS seq
          FROM TABLE(GENERATOR(ROWCOUNT => 1000)))
    WHERE seq <= $BULK_ROWS
);

ALTER SESSION UNSET QUERY_TAG;

-- Usage numbers for everything above are read in 05-05 (ACCOUNT_USAGE,
-- budget and quota views), once the views have caught up.
