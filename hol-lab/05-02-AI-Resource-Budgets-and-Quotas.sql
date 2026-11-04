/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale
Part:         PART 5 - AI Cost Governance
Section:      05-02 - Resource Budgets per Service & User Quota
Persona:      AGOV_GOVERNOR (cost administrator)
Story beat:   Different AI services can be tracked by different budgets. The same user (tagged
              BUSINESS_ANALYTICS in 05-01) drives both Cortex Agents and AI Functions, and two
              Resource Budgets split that spend by SERVICE:
                | Budget                   | Shared resource | Tracks                                       |
                |--------------------------|-----------------|----------------------------------------------|
                | AGOV_AGENT_BUDGET        | CORTEX AGENT    | CUSTOMER_INSIGHTS_AGENT, PIPELINE_OPS_AGENT  |
                | AGOV_AI_FUNCTION_BUDGET  | AI FUNCTION     | AI_COMPLETE, AI_SENTIMENT, ...               |
              05-03 generates usage on both services; 05-04 checks each budget's spend and
              custom actions; 05-05 visualizes each budget's usage side by side and, optionally,
              extends the same pattern to Snowflake CoWork and CoCo.
              A per-user QUOTA covers both services for comparison: a budget is one pooled
              monthly limit, a quota is an independent limit per user with a built-in block.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
****************************************************************************************************/

-- ⚠️  SAFETY NOTE: the tagged user is the presenter's real login - not a
--     disposable workshop user. The limits below are set to the minimum
--     (1 credit) ON PURPOSE so 05-03 can push spend past them and the
--     thresholds in 05-04 actually fire. Limits only drive notifications and
--     custom actions here: Block Enforcement stays OFF (05-04), so reaching a
--     limit never locks the presenter out of Cortex Agent / AI Functions.
--     Both SET_SPENDING_LIMIT and SET_PER_USER_LIMIT accept positive integers
--     only, so 1 credit is the smallest limit either control can have.

-- ============================================================================
-- 5.7  SECOND AGENT: PIPELINE_OPS_AGENT
--      A tool-less agent - no semantic view or Part 1-3 object dependency.
--      It gives the agent budget a second agent, so 05-05's per-entity view
--      (GET_SERVICE_TYPE_USAGE_V2 -> NAME) shows two rows under one budget.
--      Model is the already-approved Sonnet 5 (02-01 model RBAC).
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
USE WAREHOUSE AGOV_WH;
USE SCHEMA AGENTIC_GOV_DB.AGENTS;

CREATE OR REPLACE AGENT AGENTIC_GOV_DB.AGENTS.PIPELINE_OPS_AGENT
  COMMENT = 'Part 5 demo agent: tool-less, answers pipeline-operations questions from the model alone.'
  PROFILE = '{"display_name": "Pipeline Ops Agent", "color": "orange"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: claude-sonnet-5

  instructions:
    response: >
      Answer briefly (three sentences or fewer) about data pipeline operations:
      load failures, retries, schema drift, and scheduling. You have no tools and
      no access to account data; say so if asked about specific tables.
    sample_questions:
      - question: "What should I check first when a nightly load fails?"
  $$;

USE SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT;

-- ============================================================================
-- 5.8  RESOURCE BUDGET #1 - CORTEX AGENTS
--      Pooled monthly limit for every Cortex Agent call made by
--      BUSINESS_ANALYTICS users. AI Function calls never land here.
--      CREATE OR REPLACE: re-running this file recreates the budget and resets
--      its limit, scope, and any custom actions registered later in 05-04.
-- ============================================================================
CREATE OR REPLACE SNOWFLAKE.CORE.BUDGET AGENTIC_GOV_DB.COST_MANAGEMENT.AGOV_AGENT_BUDGET();

-- Minimum allowed limit (positive integer). Part 2 / Part 3 agent calls plus
-- 05-03 are enough to cross the low thresholds registered in 05-04.
CALL AGOV_AGENT_BUDGET!SET_SPENDING_LIMIT(1);

CALL AGOV_AGENT_BUDGET!SET_USER_TAGS(
    [
        [
            (SELECT SYSTEM$REFERENCE(
                'TAG',
                'AGENTIC_GOV_DB.COST_MANAGEMENT.AI_COST_CENTER',
                'SESSION',
                'APPLYBUDGET'
            )),
            'BUSINESS_ANALYTICS'
        ]
    ],
    'UNION'
);

-- Whole domain: both CUSTOMER_INSIGHTS_AGENT (02-01) and PIPELINE_OPS_AGENT (5.7).
-- To track a single agent instead, pass an instance:
--   ADD_SHARED_RESOURCE('CORTEX AGENT',
--       (SELECT SYSTEM$REFERENCE('CORTEX AGENT', 'AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT')))
-- A domain added whole cannot later be narrowed to instances, and vice versa.
CALL AGOV_AGENT_BUDGET!ADD_SHARED_RESOURCE('CORTEX AGENT');

CALL AGOV_AGENT_BUDGET!GET_BUDGET_SCOPE();

-- ============================================================================
-- 5.9  RESOURCE BUDGET #2 - AI FUNCTIONS
--      Same user tag, different service: every AI Function call (AI_COMPLETE,
--      AI_SENTIMENT, ...) made by BUSINESS_ANALYTICS users. Agent calls never
--      land here. AI FUNCTION needs no backing object.
-- ============================================================================
CREATE OR REPLACE SNOWFLAKE.CORE.BUDGET AGENTIC_GOV_DB.COST_MANAGEMENT.AGOV_AI_FUNCTION_BUDGET();

-- Minimum allowed limit; 05-03's bulk AI_COMPLETE is sized to exceed it.
CALL AGOV_AI_FUNCTION_BUDGET!SET_SPENDING_LIMIT(1);

CALL AGOV_AI_FUNCTION_BUDGET!SET_USER_TAGS(
    [
        [
            (SELECT SYSTEM$REFERENCE(
                'TAG',
                'AGENTIC_GOV_DB.COST_MANAGEMENT.AI_COST_CENTER',
                'SESSION',
                'APPLYBUDGET'
            )),
            'BUSINESS_ANALYTICS'
        ]
    ],
    'UNION'
);

-- Whole domain. To track one function instead: ADD_SHARED_RESOURCE('AI FUNCTION', 'AI_COMPLETE').
CALL AGOV_AI_FUNCTION_BUDGET!ADD_SHARED_RESOURCE('AI FUNCTION');

CALL AGOV_AI_FUNCTION_BUDGET!GET_BUDGET_SCOPE();

-- ============================================================================
-- 5.10 USER QUOTA: both services, independent per-user limit
--      Same tag, but each resolved user receives an INDEPENDENT limit rather
--      than one pooled limit. This is the only control here with a built-in
--      AI access block (05-04).
--      CORTEX CODE / SNOWFLAKE INTELLIGENCE are valid quota resources too, but
--      are left out on purpose: this HOL runs in Snowsight or your IDE, and a few hours
--      of CoCo use exceed a 1-credit daily limit on their own (see 05-05 5.22).
-- ============================================================================
CREATE OR REPLACE SNOWFLAKE.CORE.QUOTA AGENTIC_GOV_DB.COST_MANAGEMENT.AGOV_AI_QUOTA();

CALL AGOV_AI_QUOTA!SET_USER_TAGS(
    [
        [
            (SELECT SYSTEM$REFERENCE(
                'TAG',
                'AGENTIC_GOV_DB.COST_MANAGEMENT.AI_COST_CENTER',
                'SESSION',
                'APPLYBUDGET'
            )),
            'BUSINESS_ANALYTICS'
        ]
    ],
    'UNION'
);

CALL AGOV_AI_QUOTA!ADD_SHARED_RESOURCE('CORTEX AGENT');
CALL AGOV_AI_QUOTA!ADD_SHARED_RESOURCE('AI FUNCTION');

-- The DAILY limit is the one this lab demonstrates live: 05-04 adds a 10%
-- ACTUAL / DAILY notification, so the user is emailed within minutes once
-- today's spend passes 0.1 credit. Monthly and weekly limits are kept for
-- comparison (quota custom actions evaluate against the monthly limit only).
-- Block Enforcement stays OFF (05-04), so no limit here blocks the user.
CALL AGOV_AI_QUOTA!SET_PER_USER_LIMIT(5);              -- monthly
CALL AGOV_AI_QUOTA!SET_PER_USER_LIMIT(2, 'WEEKLY');
CALL AGOV_AI_QUOTA!SET_PER_USER_LIMIT(1, 'DAILY');     -- minimum (positive integer)

CALL AGOV_AI_QUOTA!GET_QUOTA_SCOPE();
CALL AGOV_AI_QUOTA!GET_USERS();
CALL AGOV_AI_QUOTA!GET_CONFIG();

-- ============================================================================
-- 5.11 BUDGET vs QUOTA - the distinction that matters
-- ============================================================================
-- A 5-credit QUOTA covering 10 tagged users permits up to 50 credits in
-- aggregate (5 x 10) because each user gets an independent limit.
-- A 5-credit BUDGET permits 5 credits for the WHOLE team combined, regardless
-- of how many users are tagged into scope.
--
--   | Requirement                              | Control        | Limit semantics        | Built-in AI block |
--   |-------------------------------------------|----------------|-------------------------|--------------------|
--   | One AI service, all consumers             | Resource budget| Shared monthly pool    | No (custom action) |
--   | Different services, separate limits       | One budget per service (this lab) | Shared monthly pool each | No (custom action) |
--   | Each user's use across AI domains          | Per-user quota | Independent per-user   | Yes                |
--
-- Evaluation speed also differs, and it shapes this lab:
--   Budget: refreshed up to ~6.5h after the spend (1h on the low-latency tier),
--           so 05-04's budget actions fire hours after 05-03, not live.
--   Quota:  evaluated within minutes, so 05-04's daily quota email is the
--           threshold you can watch fire during the session.
