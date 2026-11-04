/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale (Setup)
Story:        Five parts on one platform:
              PART 1 Data Governance        - govern data RAW -> BRONZE -> SILVER -> GOLD, then audit it.
              PART 2 Agentic Governance     - controls ON the agent: capability, inherited access, identity,
                                              and the Restricted Session Scope (RSS) session ceiling.
              PART 3 Data Movement          - approved-agent allow-list, Snowsight download control,
                                              and agent volume alert (data movement policies).
              PART 4 AI-Assisted Gov.      - use AI to govern: AI_REDACT and natural-language governance.
              PART 5 AI Cost Governance     - attribute, budget, cap, and observe AI spend (budgets, quotas,
                                              automation, optional AI Cost Control app).
File:         00 - Environment setup (roles/personas, database, schemas, grants, raw load)
Before:       Fresh account: the first model grant (section 0.7) fails until the per-model
              application roles exist. Stop after ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION
              in 0.7, run CALL SNOWFLAKE.MODELS.CORTEX_BASE_MODELS_REFRESH() as ACCOUNTADMIN,
              wait for it to finish, then continue with the grant.
              Run section 0.0 CAPTURE PRIOR SETTINGS first and record the values.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
****************************************************************************************************/

/*==================================================================================
   Database:  AGENTIC_GOV_DB
   Schemas:   RAW        - ungoverned source (stays ungoverned for contrast)
              BRONZE     - governed copy of RAW (classification + policies applied)
              SILVER     - analytics tables derived from BRONZE (governance propagates)
              GOLD       - semantic view for Cortex Analyst / agents
              GOVERNANCE - tags, masking/row/agg/projection/data-movement policies, classifiers
              AGENTS     - Cortex Agent + agent registry
              COST_MANAGEMENT - created in 05-01 (Part 5): AI cost tag, budgets, quotas, action log
   Warehouse: AGOV_WH (X-SMALL)

 PERSONAS (roles)
   AGOV_ENGINEER         - writes/tests pipeline SQL and reads BRONZE/SILVER to learn the
                           shape of the data. Never owns RAW/BRONZE/SILVER, never gets RAW
                           access at all. Subject only to masking on analytics; exempt from
                           aggregation and projection via capability database roles (01-02);
                           never granted UNMASK_ACCESS or the service role. No row-access
                           bypass capability - the analytics DT has no row access policy.
   AGOV_GOVERNOR         - DATA CUSTODIAN. Classifies, applies policies, approves agents.
                           Exempt from masking, aggregation, and projection via capability
                           database roles, and read-only on RAW/BRONZE for audit/classification
                           review - but does NOT build or own the pipeline. No row-access
                           bypass capability - the analytics DT has no row access policy.
   AGOV_PIPELINE_SERVICE_ROLE - CI/CD pipeline identity. Owns RAW, BRONZE, SILVER,
                           GOLD, and the governed semantic view; holds capability database roles (masking
                           bypass, aggregation bypass, projection bypass) since it must be
                           able to CREATE objects referencing sensitive columns without being
                           blocked. No row-access bypass capability - the analytics DT has
                           no row access policy. Kept as a role distinct from AGOV_GOVERNOR/
                           AGOV_ENGINEER so pipeline ownership stays cleanly separate.
   AGOV_ANALYST          - data consumer. SUBJECT to masking, aggregation, and projection on
                           the analytics table. Not subject to a consent RAP on analytics;
                           all customers are present. Contact activation uses a separate
                           purpose-gated secure view (CUSTOMER_CONTACT_ACTIVATION_V).
   AGOV_AUDITOR          - read-only audit / lineage / usage views.
   AGOV_CONTACT_ACTIVATOR - contact activation persona: may query the curated
                           CUSTOMER_CONTACT_ACTIVATION_V view only (name, email, phone for
                           opted-in customers with an active CONTACT_ACTIVATION entitlement).
                           Holds UNMASK_ACCESS + UNAGGREGATED_ACCESS; no RAW/BRONZE access;
                           does NOT receive SELECT on CUSTOMER_ORDER_ANALYTICS.

 Created later, not here: AGOV_COST_APP_ROLE (05-06, Part 5) owns the optional AI Cost Control app.
 Parts 2 (02-04 RSS), 3 (data movement) and 5 (cost) reuse these personas and add their own
 account-level grants in their own scripts.
==================================================================================*/

-- ============================================================================
-- 0.0  CAPTURE PRIOR SETTINGS (read-only, run BEFORE anything else)
--      The lab changes account- and user-level settings. 99-Teardown resets
--      documented defaults, not your earlier values. Run this section first and
--      copy every result OUTSIDE Snowflake (notes file, ticket). Do not store the
--      values in AGENTIC_GOV_DB: teardown drops it. The optional RESTORE section
--      in 99-Teardown uses these values.
--      Each SHOW is followed by its RESULT_SCAN. Run them as adjacent pairs.
-- ============================================================================
USE ROLE SECURITYADMIN;
SET my_user = CURRENT_USER();

-- C.1  Cross-region inference (00-Setup sets AWS_GLOBAL)
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
SELECT "key", "value", "default", "level" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- C.2  Legacy model allowlist (02-01 sets None)
SHOW PARAMETERS LIKE 'CORTEX_MODELS_ALLOWLIST' IN ACCOUNT;
SELECT "key", "value", "default", "level" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- C.3  Your DEFAULT_SECONDARY_ROLES (00-Setup sets ())
DESC USER IDENTIFIER($my_user);
SELECT "property", "value", "default" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "property" = 'DEFAULT_SECONDARY_ROLES';

-- C.4  Customer-managed model role grants to account role PUBLIC (02-01 revokes ALL)
SHOW GRANTS TO ROLE PUBLIC;
SELECT "privilege", "granted_on", "name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" ILIKE '%CORTEX-MODEL-ROLE%';

-- C.5  Snowflake-managed bootstrap on SNOWFLAKE.PUBLIC (02-01 revokes ALL)
-- ACCOUNTADMIN required: SHOW GRANTS TO APPLICATION ROLE SNOWFLAKE.PUBLIC is documented
-- as an ACCOUNTADMIN step (https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql-privileges-and-access).
USE ROLE ACCOUNTADMIN;
SHOW GRANTS TO APPLICATION ROLE SNOWFLAKE.PUBLIC;
SELECT "privilege", "granted_on", "name" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" ILIKE '%CORTEX-MODEL-ROLE%';
USE ROLE SECURITYADMIN;

-- ============================================================================
-- 0.1  ROLES
-- ============================================================================
USE ROLE SECURITYADMIN;
CREATE OR REPLACE ROLE AGOV_ENGINEER COMMENT = 'Engineer persona: writes/tests pipeline SQL, reads BRONZE/SILVER for shape; never owns RAW/BRONZE/SILVER; subject only to masking, exempt from aggregation/projection; no row-access bypass (analytics DT has no RAP)';
CREATE OR REPLACE ROLE AGOV_GOVERNOR COMMENT = 'Data custodian: classifies, applies policies, governs agents; read-only on RAW/BRONZE for audit; exempt from masking, aggregation, and projection; no row-access bypass (analytics DT has no RAP)';
CREATE OR REPLACE ROLE AGOV_ANALYST  COMMENT = 'Analyst persona: data consumer; subject to masking/aggregation/projection on analytics; all customers present (no consent RAP on analytics)';
CREATE OR REPLACE ROLE AGOV_AUDITOR  COMMENT = 'Auditor persona: read-only governance/usage viewer';
CREATE OR REPLACE ROLE AGOV_CONTACT_ACTIVATOR COMMENT = 'Contact activation persona: queries CUSTOMER_CONTACT_ACTIVATION_V only; requires CONTACT_ACTIVATION entitlement AND opt-in; holds UNMASK_ACCESS + UNAGGREGATED_ACCESS; no RAW/BRONZE or analytics DT access';
CREATE OR REPLACE ROLE AGENTIC_UNMASK_ACCESS COMMENT = 'Agent-context co-clearance: permits a UNMASK_ACCESS holder to receive clear text during agent-mediated execution; grants no clear-text access by itself';

GRANT ROLE AGOV_ENGINEER          TO ROLE SYSADMIN;
GRANT ROLE AGOV_GOVERNOR          TO ROLE SYSADMIN;
GRANT ROLE AGOV_ANALYST           TO ROLE SYSADMIN;
GRANT ROLE AGOV_AUDITOR           TO ROLE SYSADMIN;
GRANT ROLE AGOV_CONTACT_ACTIVATOR TO ROLE SYSADMIN;
GRANT ROLE AGENTIC_UNMASK_ACCESS  TO ROLE AGOV_GOVERNOR;

-- Grant all five personas (including the pipeline service role) to the current
-- user so you can role-switch through the demo with a single login - no
-- separate service-user login needed for this lab.
SET my_user = CURRENT_USER();
GRANT ROLE AGOV_ENGINEER          TO USER IDENTIFIER($my_user);
GRANT ROLE AGOV_GOVERNOR          TO USER IDENTIFIER($my_user);
GRANT ROLE AGOV_ANALYST           TO USER IDENTIFIER($my_user);
GRANT ROLE AGOV_AUDITOR           TO USER IDENTIFIER($my_user);
GRANT ROLE AGOV_CONTACT_ACTIVATOR TO USER IDENTIFIER($my_user);

-- Snowsight Data Preview (and any new session) defaults to USE SECONDARY ROLES ALL.
-- Because AGOV_ENGINEER and AGOV_GOVERNOR are in your role hierarchy via SYSADMIN,
-- IS_ROLE_IN_SESSION / IS_DATABASE_ROLE_IN_SESSION would return TRUE for the exempt
-- checks even when your primary role is AGOV_ANALYST - bypassing masking in the UI.
-- Setting DEFAULT_SECONDARY_ROLES to empty forces every new session (including the
-- Data Preview panel) to start with no secondary roles, so governance is visible in
-- the Snowsight UI
-- 99-Teardown.sql resets this to ALL when the lab is cleaned up.
ALTER USER IDENTIFIER($my_user) SET DEFAULT_SECONDARY_ROLES = ();

-- ============================================================================
-- 0.1b PIPELINE SERVICE ROLE (CI/CD identity)
--      Owns RAW/BRONZE/SILVER/GOLD and holds every policy-bypass capability, kept as
--      a SEPARATE role from AGOV_GOVERNOR/AGOV_ENGINEER so ownership of the
--      pipeline stays cleanly distinct from both the governance persona and the
--      pipeline-building persona - even though, for this lab, all personas are
--      granted to the same demo user and switched between with USE ROLE rather
--      than a dedicated non-interactive service user/login. In a real
--      deployment this role would be granted only to a service user with
--      key-pair/OAuth auth (no interactive login), and pipeline steps would run
--      unattended via a Task / DCM project / dbt run under those credentials -
--      the lab simplifies that down to a literal USE ROLE AGOV_PIPELINE_SERVICE_ROLE.
-- ============================================================================
CREATE OR REPLACE ROLE AGOV_PIPELINE_SERVICE_ROLE
    COMMENT = 'CI/CD pipeline identity: owns RAW/BRONZE/SILVER/GOLD pipeline objects and the governed semantic view; holds masking/aggregation/projection bypass capabilities. In production, granted only to a non-interactive service user - in this lab, granted to the demo user and reached via USE ROLE for simplicity.';
GRANT ROLE AGOV_PIPELINE_SERVICE_ROLE TO ROLE SYSADMIN;
GRANT ROLE AGOV_PIPELINE_SERVICE_ROLE TO USER IDENTIFIER($my_user);

-- ============================================================================
-- 0.2  WAREHOUSE
-- ============================================================================
USE ROLE SYSADMIN;
CREATE OR REPLACE WAREHOUSE AGOV_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Agentic Governance demo warehouse';

GRANT USAGE, OPERATE ON WAREHOUSE AGOV_WH TO ROLE AGOV_ENGINEER;
GRANT USAGE, OPERATE ON WAREHOUSE AGOV_WH TO ROLE AGOV_GOVERNOR;
GRANT USAGE          ON WAREHOUSE AGOV_WH TO ROLE AGOV_ANALYST;
GRANT USAGE, OPERATE ON WAREHOUSE AGOV_WH TO ROLE AGOV_AUDITOR;
GRANT USAGE, OPERATE ON WAREHOUSE AGOV_WH TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT USAGE          ON WAREHOUSE AGOV_WH TO ROLE AGOV_CONTACT_ACTIVATOR;

-- ============================================================================
-- 0.3  DATABASE + SCHEMAS
--      AGOV_ENGINEER owns only the DATABASE container. The CI/CD service role owns
--      RAW/BRONZE/SILVER/GOLD and publishes the governed semantic view so every
--      deployable data product is owned by the non-human pipeline identity.
-- ============================================================================
GRANT CREATE DATABASE ON ACCOUNT TO ROLE AGOV_ENGINEER;

USE ROLE AGOV_ENGINEER;
CREATE OR REPLACE DATABASE AGENTIC_GOV_DB;

GRANT CREATE SCHEMA ON DATABASE AGENTIC_GOV_DB TO ROLE AGOV_PIPELINE_SERVICE_ROLE;

USE ROLE AGOV_PIPELINE_SERVICE_ROLE;
CREATE OR REPLACE SCHEMA AGENTIC_GOV_DB.RAW    COMMENT = 'RAW: ungoverned source (stays ungoverned for contrast)';
CREATE OR REPLACE SCHEMA AGENTIC_GOV_DB.BRONZE COMMENT = 'BRONZE: governed copy of RAW';
CREATE OR REPLACE SCHEMA AGENTIC_GOV_DB.SILVER COMMENT = 'SILVER: analytics derived from BRONZE';
CREATE OR REPLACE SCHEMA AGENTIC_GOV_DB.GOLD   COMMENT = 'GOLD: CI/CD-published semantic views for AI / Cortex Analyst';

-- ============================================================================
-- 0.4  DATABASE / SCHEMA USAGE (all personas)
-- ============================================================================
USE ROLE AGOV_ENGINEER;
GRANT USAGE ON DATABASE AGENTIC_GOV_DB TO ROLE AGOV_GOVERNOR;
GRANT USAGE ON DATABASE AGENTIC_GOV_DB TO ROLE AGOV_ANALYST;
GRANT USAGE ON DATABASE AGENTIC_GOV_DB TO ROLE AGOV_AUDITOR;
GRANT USAGE ON DATABASE AGENTIC_GOV_DB TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT USAGE ON DATABASE AGENTIC_GOV_DB TO ROLE AGOV_CONTACT_ACTIVATOR;

GRANT CREATE SCHEMA ON DATABASE AGENTIC_GOV_DB TO ROLE AGOV_GOVERNOR;

-- Medallion schemas: USAGE scoped by access tier
-- AGOV_ANALYST/AUDITOR only need SILVER + GOLD + GOVERNANCE (ANALYST never queries BRONZE/RAW)
USE ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.RAW    TO ROLE AGOV_GOVERNOR;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.RAW    TO ROLE AGOV_AUDITOR;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.BRONZE TO ROLE AGOV_GOVERNOR;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.BRONZE TO ROLE AGOV_ENGINEER;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.BRONZE TO ROLE AGOV_AUDITOR;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_GOVERNOR;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_ENGINEER;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_ANALYST;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_AUDITOR;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_CONTACT_ACTIVATOR;  -- view access only, no DT/table grants

USE ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.GOLD   TO ROLE AGOV_GOVERNOR;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.GOLD   TO ROLE AGOV_ENGINEER;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.GOLD   TO ROLE AGOV_ANALYST;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.GOLD   TO ROLE AGOV_AUDITOR;

-- ============================================================================
-- 0.5  GOVERNANCE + AGENTS + COST_MANAGEMENT SCHEMAS (governor owns - pure
--      governance, unaffected by the pipeline-ownership redesign above)
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
CREATE OR REPLACE SCHEMA AGENTIC_GOV_DB.GOVERNANCE COMMENT = 'Tags, policies, classifiers, mapping tables';
CREATE OR REPLACE SCHEMA AGENTIC_GOV_DB.AGENTS     COMMENT = 'Cortex Agent + agent registry';

GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.GOVERNANCE TO ROLE AGOV_ENGINEER;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.GOVERNANCE TO ROLE AGOV_ANALYST;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.GOVERNANCE TO ROLE AGOV_AUDITOR;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.GOVERNANCE TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.AGENTS     TO ROLE AGOV_ENGINEER;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.AGENTS     TO ROLE AGOV_ANALYST;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.AGENTS     TO ROLE AGOV_AUDITOR;

-- Cost attribution tag for Part 5. Created and applied here, not in 05-01:
-- Cortex Agents record the caller's user tags with each request (USER_TAGS,
-- point-in-time), so tagging up front lets every agent call from Part 2
-- onward count toward the Part 5 budgets, quota, and cost-center views.
-- COST_MANAGEMENT stays separate from GOVERNANCE so cost controls can be
-- changed or removed without touching the data-governance objects.
CREATE OR REPLACE SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT
    COMMENT = 'AI cost attribution, resource budgets, user quotas, and enforcement automation. Deliberately separate from GOVERNANCE.';

CREATE OR REPLACE TAG AGENTIC_GOV_DB.COST_MANAGEMENT.AI_COST_CENTER
    ALLOWED_VALUES 'BUSINESS_ANALYTICS'
    COMMENT = 'AI spend attribution tag for Snowflake Budgets/Quotas. Applied to USERS (not roles) - budget/quota scoping resolves via user tags.';
-- The tag is applied to your user at the end of 0.7, after SECURITYADMIN holds APPLY TAG.

-- ============================================================================
-- 0.6  TABLE / DYNAMIC TABLE / PROCEDURE GRANTS
--      AGOV_PIPELINE_SERVICE_ROLE owns and fully controls RAW, BRONZE, and the
--      SILVER dynamic table. AGOV_GOVERNOR and AGOV_ENGINEER are READ-ONLY on
--      RAW/BRONZE - neither builds these layers. AGOV_GOVERNOR
--      keeps OPERATE (not ownership) on the SILVER DT so it can still attach the
--      row-access/aggregation policies and tags in 01-02 without owning the object.
-- ============================================================================
USE ROLE SECURITYADMIN;

-- RAW: service role owns/writes; governor + auditor read-only (sensitive-access
-- proof / audit review); ENGINEER has NO access - untagged source is off-limits.
GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN SCHEMA AGENTIC_GOV_DB.RAW TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL    TABLES IN SCHEMA AGENTIC_GOV_DB.RAW TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA AGENTIC_GOV_DB.RAW TO ROLE AGOV_GOVERNOR;
GRANT SELECT ON FUTURE TABLES IN SCHEMA AGENTIC_GOV_DB.RAW TO ROLE AGOV_AUDITOR;
GRANT SELECT ON ALL    TABLES IN SCHEMA AGENTIC_GOV_DB.RAW TO ROLE AGOV_GOVERNOR;
GRANT SELECT ON ALL    TABLES IN SCHEMA AGENTIC_GOV_DB.RAW TO ROLE AGOV_AUDITOR;

-- BRONZE: service role owns/writes (built directly, no procedure indirection);
-- governor read (sensitive-access proof, 02-03); engineer read-only (masked -
-- fine per design, the constraint is ownership of the DT/table, not read access);
-- auditor read; ANALYST excluded (accesses governed SILVER only).
GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN SCHEMA AGENTIC_GOV_DB.BRONZE TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL    TABLES IN SCHEMA AGENTIC_GOV_DB.BRONZE TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA AGENTIC_GOV_DB.BRONZE TO ROLE AGOV_GOVERNOR;
GRANT SELECT ON FUTURE TABLES IN SCHEMA AGENTIC_GOV_DB.BRONZE TO ROLE AGOV_ENGINEER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA AGENTIC_GOV_DB.BRONZE TO ROLE AGOV_AUDITOR;
GRANT SELECT ON ALL    TABLES IN SCHEMA AGENTIC_GOV_DB.BRONZE TO ROLE AGOV_GOVERNOR;
GRANT SELECT ON ALL    TABLES IN SCHEMA AGENTIC_GOV_DB.BRONZE TO ROLE AGOV_ENGINEER;
GRANT SELECT ON ALL    TABLES IN SCHEMA AGENTIC_GOV_DB.BRONZE TO ROLE AGOV_AUDITOR;

-- SILVER (plain tables - the AI_REDACT pre-computed table in Part 4 lives here,
-- built by AGOV_GOVERNOR; unrelated to the CUSTOMER_ORDER_ANALYTICS dynamic table).
GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_GOVERNOR;
GRANT SELECT                         ON FUTURE TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_ANALYST;
GRANT SELECT                         ON FUTURE TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_AUDITOR;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL    TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_GOVERNOR;
GRANT SELECT                         ON ALL    TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_ANALYST;
GRANT SELECT                         ON ALL    TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_AUDITOR;

-- SILVER Dynamic Table: AGOV_PIPELINE_SERVICE_ROLE creates and owns it directly
--  AGOV_GOVERNOR keeps OPERATE (not ownership) to attach row-access/aggregation 
-- policies and tags afterward.
-- AGOV_ENGINEER does not get CREATE DYNAMIC TABLE on SILVER at all - it only
-- reads the DT afterward (masked) to learn the pipeline's output shape.
GRANT CREATE DYNAMIC TABLE ON SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE, OPERATE ON FUTURE DYNAMIC TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE, OPERATE ON ALL    DYNAMIC TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT OPERATE, SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_GOVERNOR;
GRANT OPERATE, SELECT ON ALL    DYNAMIC TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_GOVERNOR;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_ANALYST;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_AUDITOR;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_ENGINEER;
GRANT SELECT ON ALL    DYNAMIC TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_ANALYST;
GRANT SELECT ON ALL    DYNAMIC TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_AUDITOR;
GRANT SELECT ON ALL    DYNAMIC TABLES IN SCHEMA AGENTIC_GOV_DB.SILVER TO ROLE AGOV_ENGINEER;

-- GOLD semantic views: built and owned by the CI/CD service role from governed
-- SILVER data; readable by the human personas so Cortex Analyst works per caller.
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA AGENTIC_GOV_DB.GOLD TO ROLE AGOV_GOVERNOR;
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA AGENTIC_GOV_DB.GOLD TO ROLE AGOV_ANALYST;
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA AGENTIC_GOV_DB.GOLD TO ROLE AGOV_ENGINEER;
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA AGENTIC_GOV_DB.GOLD TO ROLE AGOV_AUDITOR;
GRANT SELECT ON ALL    SEMANTIC VIEWS IN SCHEMA AGENTIC_GOV_DB.GOLD TO ROLE AGOV_GOVERNOR;
GRANT SELECT ON ALL    SEMANTIC VIEWS IN SCHEMA AGENTIC_GOV_DB.GOLD TO ROLE AGOV_ANALYST;
GRANT SELECT ON ALL    SEMANTIC VIEWS IN SCHEMA AGENTIC_GOV_DB.GOLD TO ROLE AGOV_AUDITOR;

-- Custom DMF definition (INVALID_EMAIL_COUNT, 01-01) lives in GOVERNANCE and is
-- created directly by AGOV_PIPELINE_SERVICE_ROLE - no procedure needed.
-- CREATE DATA METRIC FUNCTION is a distinct privilege from CREATE FUNCTION -
-- LIVE-CONFIRMED: a plain CREATE FUNCTION grant is not sufficient for a DMF.
GRANT CREATE FUNCTION             ON SCHEMA AGENTIC_GOV_DB.GOVERNANCE TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT CREATE DATA METRIC FUNCTION ON SCHEMA AGENTIC_GOV_DB.GOVERNANCE TO ROLE AGOV_PIPELINE_SERVICE_ROLE;

-- ============================================================================
-- 0.7  ACCOUNT-LEVEL GOVERNANCE PRIVILEGES (governor = data custodian)
--      SECURITYADMIN grants account privileges through MANAGE GRANTS. Only the
--      labeled ACCOUNTADMIN block below needs ACCOUNTADMIN.
-- ============================================================================
USE ROLE SECURITYADMIN;

-- SECURITYADMIN self-grants for the lab (revoked in 99-Teardown):
--   APPLY SESSION POLICY - attach/detach the RSS session policy on your user (02-04)
--   APPLY TAG            - set AI_COST_CENTER on your user (end of 0.7)
--   GOVERNANCE_VIEWER    - ACCOUNT_USAGE evidence reads (03-01.10)
--   AGOV_WH, AGENTIC_GOV_DB, GOVERNANCE USAGE - run the 02-04 RSS steps and policy reads
GRANT APPLY SESSION POLICY ON ACCOUNT TO ROLE SECURITYADMIN;
GRANT USAGE ON WAREHOUSE AGOV_WH                   TO ROLE SECURITYADMIN;
GRANT USAGE ON DATABASE AGENTIC_GOV_DB             TO ROLE SECURITYADMIN;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.GOVERNANCE    TO ROLE SECURITYADMIN;
GRANT APPLY TAG            ON ACCOUNT TO ROLE SECURITYADMIN;
-- verified in rehearsal 2026-11-02
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE SECURITYADMIN;

GRANT APPLY TAG                ON ACCOUNT TO ROLE AGOV_GOVERNOR;
GRANT APPLY MASKING POLICY     ON ACCOUNT TO ROLE AGOV_GOVERNOR;
GRANT APPLY ROW ACCESS POLICY  ON ACCOUNT TO ROLE AGOV_GOVERNOR;
GRANT APPLY AGGREGATION POLICY ON ACCOUNT TO ROLE AGOV_GOVERNOR;
GRANT APPLY PROJECTION POLICY  ON ACCOUNT TO ROLE AGOV_GOVERNOR;

-- Classification + auto-tagging
-- verified in rehearsal 2026-11-02
GRANT DATABASE ROLE SNOWFLAKE.CLASSIFICATION_ADMIN TO ROLE AGOV_GOVERNOR;
-- verified in rehearsal 2026-11-02
GRANT EXECUTE AUTO CLASSIFICATION ON ACCOUNT        TO ROLE AGOV_GOVERNOR;

-- Data quality (DMFs): the service role owns BRONZE and attaches DMFs directly
-- (01-01, no procedure); governor keeps DMF privileges for governance review.
-- verified in rehearsal 2026-11-02
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE AGOV_GOVERNOR;
-- verified in rehearsal 2026-11-02
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT  TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT  TO ROLE AGOV_GOVERNOR;

-- Audit / usage views (ACCOUNT_USAGE) for governor + auditor.
-- GOVERNANCE_VIEWER covers ACCESS_HISTORY, QUERY_HISTORY, CORTEX_AGENT_USAGE_HISTORY, etc.
-- verified in rehearsal 2026-11-02
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE AGOV_GOVERNOR;
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE AGOV_AUDITOR;
GRANT DATABASE ROLE SNOWFLAKE.OBJECT_VIEWER     TO ROLE AGOV_AUDITOR;
GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER      TO ROLE AGOV_AUDITOR;

-- Cortex AI (semantic views via Cortex Analyst, AI_REDACT, agents, Part 3/5 demo agents and
-- AI-function usage that Part 5 meters) for all personas
-- verified in rehearsal 2026-11-02
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE AGOV_ENGINEER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE AGOV_GOVERNOR;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE AGOV_ANALYST;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE AGOV_AUDITOR;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE AGOV_CONTACT_ACTIVATOR;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE AGOV_PIPELINE_SERVICE_ROLE;

-- ----------------------------------------------------------------------------
-- ACCOUNTADMIN required: account parameter, model catalog refresh, and SNOWFLAKE
-- application-role grants. MANAGE GRANTS does not cover SNOWFLAKE application roles
-- (https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql-privileges-and-access).
-- ----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

-- Cross-region inference: Claude Sonnet may not be available in every region.
-- AWS_GLOBAL routes Cortex LLM calls to any AWS region where the model is available.
-- Required for the model-RBAC and agent demos in Part 2 and the AI cost demos in Part 5.
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'AWS_GLOBAL';

-- Refresh SNOWFLAKE.MODELS so the per-model application roles (including Claude Sonnet)
-- are populated after cross-region is enabled. This is a SLOW, one-time step: it takes
-- several minutes (around 5 min observed). On a fresh account it must complete BEFORE
-- the first model grant below (see Before: in the header). Run it again after new
-- models are released. It stays commented out so a batch rerun does not repeat it.
-- CALL SNOWFLAKE.MODELS.CORTEX_BASE_MODELS_REFRESH();

-- Model RBAC: grant the analyst the approved model application role so Part 2
-- (02-01) can validate capability governance without a separate one-time setup step.
GRANT APPLICATION ROLE SNOWFLAKE."CORTEX-MODEL-ROLE-CLAUDE-SONNET-5" TO ROLE AGOV_ANALYST;

-- Part 5 (05-01): EVENTS_VIEWER is an APPLICATION role of the SNOWFLAKE app. It lets
-- governor and auditor read AI observability events in the default event table.
GRANT APPLICATION ROLE SNOWFLAKE.EVENTS_VIEWER TO ROLE AGOV_GOVERNOR;
GRANT APPLICATION ROLE SNOWFLAKE.EVENTS_VIEWER TO ROLE AGOV_AUDITOR;
-- End of ACCOUNTADMIN block.

USE ROLE SECURITYADMIN;

-- Governor authors policies/functions/agents. The CI/CD role owns GOLD and can
-- create semantic views there without an additional schema privilege grant.
GRANT CREATE FUNCTION      ON SCHEMA AGENTIC_GOV_DB.GOVERNANCE TO ROLE AGOV_GOVERNOR;
GRANT CREATE TABLE         ON SCHEMA AGENTIC_GOV_DB.GOVERNANCE TO ROLE AGOV_GOVERNOR;
-- AI_REDACT pre-computed table lives in SILVER (governor writes it - Part 4 feature,
-- unrelated to the service-role-owned CUSTOMER_ORDER_ANALYTICS dynamic table)
GRANT CREATE TABLE         ON SCHEMA AGENTIC_GOV_DB.SILVER     TO ROLE AGOV_GOVERNOR;
GRANT CREATE VIEW          ON SCHEMA AGENTIC_GOV_DB.SILVER     TO ROLE AGOV_GOVERNOR;
-- Agent objects + registry
GRANT CREATE AGENT         ON SCHEMA AGENTIC_GOV_DB.AGENTS     TO ROLE AGOV_GOVERNOR;
GRANT CREATE TABLE         ON SCHEMA AGENTIC_GOV_DB.AGENTS     TO ROLE AGOV_GOVERNOR;
GRANT CREATE VIEW          ON SCHEMA AGENTIC_GOV_DB.AGENTS     TO ROLE AGOV_GOVERNOR;

-- Database-role creation privilege: AGOV_GOVERNOR creates and owns the three
-- policy-bypass capability database roles (01-02) - UNMASK_ACCESS,
-- UNAGGREGATED_ACCESS, UNRESTRICTED_PROJECTION_ACCESS - the single, semantic "may
-- bypass X" capability per policy type, granted to whichever functional/service
-- roles need it instead of hard-coding functional-role names into policy bodies.
-- ALL_ROWS_ACCESS no longer exists: analytics DT has no row access policy.
GRANT CREATE DATABASE ROLE ON DATABASE AGENTIC_GOV_DB TO ROLE AGOV_GOVERNOR;

-- Cost attribution tag on your user (see 0.5). SECURITYADMIN holds APPLY TAG from above.
ALTER USER IDENTIFIER($my_user)
    SET TAG AGENTIC_GOV_DB.COST_MANAGEMENT.AI_COST_CENTER = 'BUSINESS_ANALYTICS';

-- ============================================================================
-- 0.8  RAW LOAD (synthetic customer data from public S3)
--      Runs directly as AGOV_PIPELINE_SERVICE_ROLE - no procedure indirection.
--      AGOV_ENGINEER never runs this section and never gets RAW access at all;
--      in production this step would run unattended via a Task / DCM project /
--      dbt run under the service account's credentials.
-- ============================================================================
USE ROLE AGOV_PIPELINE_SERVICE_ROLE;
USE WAREHOUSE AGOV_WH;
USE DATABASE AGENTIC_GOV_DB;
USE SCHEMA RAW;

CREATE OR REPLACE TABLE AGENTIC_GOV_DB.RAW.CUSTOMER_RAW (
    ID FLOAT, FIRST_NAME VARCHAR, LAST_NAME VARCHAR, STREET_ADDRESS VARCHAR,
    STATE VARCHAR, CITY VARCHAR, ZIP VARCHAR, PHONE_NUMBER VARCHAR, EMAIL VARCHAR,
    SSN VARCHAR, BIRTHDATE VARCHAR, JOB VARCHAR, CREDITCARD VARCHAR,
    COMPANY VARCHAR, OPTIN VARCHAR
);

CREATE OR REPLACE TABLE AGENTIC_GOV_DB.RAW.CUSTOMER_ORDERS_RAW (
    CUSTOMER_ID VARCHAR, ORDER_ID VARCHAR, ORDER_TS DATE, ORDER_CURRENCY VARCHAR,
    ORDER_AMOUNT FLOAT, ORDER_TAX FLOAT, ORDER_TOTAL FLOAT
);

CREATE OR REPLACE STAGE AGENTIC_GOV_DB.RAW.FIXTURE_SOURCE
    URL = 's3://sfquickstarts/summit_2024_horizon_hol/'
    FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);

COPY INTO AGENTIC_GOV_DB.RAW.CUSTOMER_RAW
FROM (
    SELECT METADATA$FILE_ROW_NUMBER,
           source.$2, source.$3, source.$4, source.$5, source.$6,
           source.$7, source.$8, source.$9, source.$10, source.$11,
           source.$12, source.$13, source.$14, source.$15
    FROM @AGENTIC_GOV_DB.RAW.FIXTURE_SOURCE/CustomerDataRaw.csv source
)
FILE_FORMAT = (TYPE = 'CSV', SKIP_HEADER = 1);

COPY INTO AGENTIC_GOV_DB.RAW.CUSTOMER_ORDERS_RAW
FROM (
    SELECT source.$1, METADATA$FILE_ROW_NUMBER,
           source.$3, source.$4, source.$5, source.$6, source.$7
    FROM @AGENTIC_GOV_DB.RAW.FIXTURE_SOURCE/CustomerOrders.csv source
)
FILE_FORMAT = (TYPE = 'CSV', SKIP_HEADER = 1);

UPDATE AGENTIC_GOV_DB.RAW.CUSTOMER_RAW
SET BIRTHDATE = TO_CHAR(DATEADD('day', MOD(ID * 37, 18000), DATE '1950-01-01'), 'YYYY-MM-DD');

UPDATE AGENTIC_GOV_DB.RAW.CUSTOMER_ORDERS_RAW
SET CUSTOMER_ID = TO_VARCHAR(MOD(TO_NUMBER(ORDER_ID) - 1, 900) + 1);

-- ============================================================================
-- 0.9  VALIDATION
-- ============================================================================
SELECT 'CUSTOMER_RAW'        AS table_name, COUNT(*) AS row_count FROM AGENTIC_GOV_DB.RAW.CUSTOMER_RAW
UNION ALL
SELECT 'CUSTOMER_ORDERS_RAW' AS table_name, COUNT(*) AS row_count FROM AGENTIC_GOV_DB.RAW.CUSTOMER_ORDERS_RAW;
