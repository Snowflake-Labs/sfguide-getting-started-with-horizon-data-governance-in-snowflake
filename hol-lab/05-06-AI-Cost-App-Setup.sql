/*************************************************************************************************************
Script:       05-06-AI-Cost-App-Setup.sql
Part:         PART 5 - AI Cost Governance (OPTIONAL)
Section:      5.23 AI Cost Control App - role and grants
Purpose:      Prepare AGOV_COST_APP_ROLE, the owner role of the "AI Cost Control" Snowflake App
              (hol-lab/ai-cost-control-app). The app shows every Cortex AI service in one place:
                - Daily credits per service: Cortex Agents, AI Functions, Snowflake CoWork,
                  CoCo CLI / Desktop / Snowsight, Cortex Analyst, Cortex Search
                - Cost center attribution from the AI_COST_CENTER user tag, including UNTAGGED
                - Budget status for the two 05-02 budgets
                - Per-user quota spend (AGOV_AI_QUOTA)
                - Credits by model, and AI vs warehouse credits per user
                - Whole-account Cortex AI totals from METERING_HISTORY next to the
                  per-service views (same two lenses as 05-05 5.22)
Run after:    05-01 .. 05-05. USERADMIN creates the role, SECURITYADMIN grants it.
Next:         See hol-lab/ai-cost-control-app/README.md to run it locally from your IDE terminal
              or deploy it with `snow app deploy`.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
*************************************************************************************************************/

-- ============================================================================
-- 5.23a APP ROLE
-- ============================================================================
USE ROLE USERADMIN;
CREATE ROLE IF NOT EXISTS AGOV_COST_APP_ROLE
    COMMENT = 'Owner role for the AI Cost Control Snowflake App (Part 5)';

USE ROLE SECURITYADMIN;
SET my_user = CURRENT_USER();
GRANT ROLE AGOV_COST_APP_ROLE TO USER IDENTIFIER($my_user);
GRANT ROLE AGOV_COST_APP_ROLE TO ROLE SYSADMIN;

-- ============================================================================
-- 5.23b READ ACCESS: ACCOUNT_USAGE (usage views, query + attribution history)
--      USAGE_VIEWER     -> CORTEX_*_USAGE_HISTORY, CoCo / CoWork views,
--                          METERING_HISTORY, QUERY_ATTRIBUTION_HISTORY
--      GOVERNANCE_VIEWER-> QUERY_HISTORY (user of an AI function call),
--                          TAG_REFERENCES (current tag of a user)
-- ============================================================================
-- verified in rehearsal 2026-11-02
GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER      TO ROLE AGOV_COST_APP_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE AGOV_COST_APP_ROLE;

-- ============================================================================
-- 5.23c READ ACCESS: budgets and quota (instance VIEWER roles)
-- ============================================================================
GRANT SNOWFLAKE.CORE.BUDGET ROLE AGENTIC_GOV_DB.COST_MANAGEMENT.AGOV_AGENT_BUDGET!VIEWER
    TO ROLE AGOV_COST_APP_ROLE;
GRANT SNOWFLAKE.CORE.BUDGET ROLE AGENTIC_GOV_DB.COST_MANAGEMENT.AGOV_AI_FUNCTION_BUDGET!VIEWER
    TO ROLE AGOV_COST_APP_ROLE;
GRANT SNOWFLAKE.CORE.QUOTA ROLE AGENTIC_GOV_DB.COST_MANAGEMENT.AGOV_AI_QUOTA!VIEWER
    TO ROLE AGOV_COST_APP_ROLE;

GRANT SELECT ON TABLE AGENTIC_GOV_DB.COST_MANAGEMENT.AI_BUDGET_ACTION_LOG TO ROLE AGOV_COST_APP_ROLE;

-- ============================================================================
-- 5.23d COMPUTE + DEPLOY PRIVILEGES
--      The app reuses AGOV_WH as its query warehouse. Deployment creates an
--      APPLICATION SERVICE plus a build stage / artifact repository in
--      AGENTIC_GOV_DB.COST_MANAGEMENT. Local runs only need the first three grants.
-- ============================================================================
GRANT USAGE ON WAREHOUSE AGOV_WH                        TO ROLE AGOV_COST_APP_ROLE;
GRANT USAGE ON DATABASE AGENTIC_GOV_DB                  TO ROLE AGOV_COST_APP_ROLE;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT    TO ROLE AGOV_COST_APP_ROLE;

GRANT CREATE APPLICATION SERVICE ON SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT TO ROLE AGOV_COST_APP_ROLE;
GRANT CREATE ARTIFACT REPOSITORY ON SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT TO ROLE AGOV_COST_APP_ROLE;
GRANT CREATE STAGE               ON SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT TO ROLE AGOV_COST_APP_ROLE;

-- ============================================================================
-- 5.23e SMOKE TEST - everything the app reads, as the app role
-- ============================================================================
USE ROLE AGOV_COST_APP_ROLE;
USE WAREHOUSE AGOV_WH;

CALL AGENTIC_GOV_DB.COST_MANAGEMENT.AGOV_AGENT_BUDGET!GET_SPENDING_LIMIT();
CALL AGENTIC_GOV_DB.COST_MANAGEMENT.AGOV_AI_QUOTA!GET_CONFIG();

SELECT 'agents' AS src, COUNT(*) AS n_rows FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
UNION ALL SELECT 'ai_functions', COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
UNION ALL SELECT 'coco_desktop', COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_DESKTOP_USAGE_HISTORY
UNION ALL SELECT 'cowork', COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COWORK_USAGE_HISTORY
UNION ALL SELECT 'wh_attribution', COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY;
