/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale
Part:         PART 5 - AI Cost Governance
Section:      05-01 - Cost Management Setup and Attribution
Persona:      AGOV_GOVERNOR (data custodian, now also cost administrator)
Story beat:   Governing WHO may see data and WHICH agent may run it (Parts 1-2) is not the whole
              story - AI consumption also costs real credits. 00-Setup.sql already created the
              AGENTIC_GOV_DB.COST_MANAGEMENT schema (deliberately separate from GOVERNANCE) and
              tagged CURRENT_USER() with AI_COST_CENTER = 'BUSINESS_ANALYTICS', so every AI call
              since Part 2 is already attributed. This section grants the custodian the
              budget/quota capabilities and creates the action log used in 05-04.
              No extra user is created: 05-02 splits this one user's spend by SERVICE
              (Cortex Agents vs AI Functions) into two budgets, rather than by user.
              Attribution queries (who spent what, by cost center) are all in 05-05.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
****************************************************************************************************/

-- ============================================================================
-- 5.1  PRIVILEGES: AGOV_GOVERNOR becomes the cost administrator, AGOV_AUDITOR
--      keeps its read-only observer role and gains telemetry visibility.
--      Budget/Quota creation privileges are distinct from ordinary object
--      privileges (SNOWFLAKE.CORE.BUDGET / SNOWFLAKE.CORE.QUOTA), same as the
--      distinct CREATE DATA METRIC FUNCTION privilege proven in 00-Setup.sql.
-- ============================================================================
USE ROLE SECURITYADMIN;

-- verified in rehearsal 2026-11-02
GRANT DATABASE ROLE SNOWFLAKE.BUDGET_CREATOR TO ROLE AGOV_GOVERNOR;
GRANT DATABASE ROLE SNOWFLAKE.QUOTA_CREATOR  TO ROLE AGOV_GOVERNOR;
-- EVENTS_VIEWER is an APPLICATION role of the SNOWFLAKE app (not a database
-- role); it grants read access to SNOWFLAKE.TELEMETRY.EVENTS_VIEW (05-04 5.15).
-- It is granted in the ACCOUNTADMIN block of 00-Setup.sql 0.7, because MANAGE
-- GRANTS does not cover SNOWFLAKE application roles.

-- ============================================================================
-- 5.2  COST_MANAGEMENT SCHEMA ACCESS
--      The schema itself is created in 00-Setup.sql (0.5). It holds only
--      budget/quota/tag/log objects that this Part owns end to end, so dropping
--      or redesigning cost controls later never risks the data-governance layer.
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
USE WAREHOUSE AGOV_WH;
USE DATABASE AGENTIC_GOV_DB;

GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT TO ROLE AGOV_AUDITOR;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT TO ROLE AGOV_ANALYST;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT TO ROLE AGOV_ENGINEER;

-- Budget/Quota creation privilege is schema-scoped, same pattern as
-- CREATE DATA METRIC FUNCTION in 00-Setup.sql 0.6.
-- ACCOUNTADMIN required: SECURITYADMIN gets Insufficient privileges to operate
-- on class 'BUDGET' (rehearsal 2026-11-02)
USE ROLE ACCOUNTADMIN;
GRANT CREATE SNOWFLAKE.CORE.BUDGET ON SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT TO ROLE AGOV_GOVERNOR;
GRANT CREATE SNOWFLAKE.CORE.QUOTA  ON SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT TO ROLE AGOV_GOVERNOR;
USE ROLE SECURITYADMIN;

-- The SNOWFLAKE application needs parent-object access before the
-- procedure-specific USAGE grants in 05-04 can be issued after creation -
-- identical precondition to the DMF/procedure grants in 00-Setup.sql 0.6.
GRANT USAGE ON DATABASE AGENTIC_GOV_DB               TO APPLICATION SNOWFLAKE;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT TO APPLICATION SNOWFLAKE;

-- ============================================================================
-- 5.3  COST-CENTER TAG PRIVILEGES
--      The AI_COST_CENTER tag (created and applied to the demo user in
--      00-Setup.sql) is purpose-built for spend attribution - not a reuse of
--      DATA_CLASSIFICATION (that tag drives masking tiers; conflating the two
--      would let a masking decision accidentally change a budget scope).
--      One value is enough for this lab: BUSINESS_ANALYTICS. Both budgets in
--      05-02 scope to it; they differ by service, not by tag.
--      APPLYBUDGET is what lets 05-02 scope budgets and the quota to the tag.
-- ============================================================================
USE ROLE AGOV_GOVERNOR;

GRANT APPLY ON TAG AGENTIC_GOV_DB.COST_MANAGEMENT.AI_COST_CENTER TO ROLE AGOV_GOVERNOR;
GRANT APPLYBUDGET ON TAG AGENTIC_GOV_DB.COST_MANAGEMENT.AI_COST_CENTER TO ROLE AGOV_GOVERNOR;

-- ============================================================================
-- 5.4  ACTION LOG TABLE
--      Idempotent audit trail for budget/quota custom actions registered in
--      05-04. Lives in COST_MANAGEMENT, not GOVERNANCE.
-- ============================================================================
CREATE TABLE IF NOT EXISTS AGENTIC_GOV_DB.COST_MANAGEMENT.AI_BUDGET_ACTION_LOG (
    EVENT_ID    VARCHAR NOT NULL,
    EVENT_TIME  TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONTROL_NAME VARCHAR NOT NULL,
    ACTION_NAME  VARCHAR NOT NULL,
    SCOPE_NAME   VARCHAR,
    THRESHOLD    NUMBER,
    DETAILS      VARIANT,
    CONSTRAINT AI_BUDGET_ACTION_LOG_PK PRIMARY KEY (EVENT_ID)
);

GRANT SELECT, INSERT, UPDATE ON TABLE AGENTIC_GOV_DB.COST_MANAGEMENT.AI_BUDGET_ACTION_LOG TO ROLE AGOV_GOVERNOR;
GRANT SELECT ON TABLE AGENTIC_GOV_DB.COST_MANAGEMENT.AI_BUDGET_ACTION_LOG TO ROLE AGOV_AUDITOR;
