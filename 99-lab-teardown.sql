
/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S | 
|
|Demo:         Horizon Lab - Teardown Script
|Version:      HLab v2.0
|Create Date:  Apr 17, 2024
|Author:       Ravi Kumar
|Co-Authors:   Ben Weiss, Susan Devitt, Severin Gassauer
|Copyright(c): 2026 Snowflake Inc. All rights reserved.
|****************************************************************************************************/
/****************************************************************************************************
|SUMMARY OF CHANGES
|Date(yyyy-mm-dd)    Author              Comments
|------------------- ------------------- ------------------------------------------------------------
|Apr 17, 2024        Ravi Kumar           Initial Lab
|Jan 26, 2026        Severin Gassauer     Added AI governance cleanup
|***************************************************************************************************/

/********************/
-- T E A R   D O W N
/********************/

-- ============================================================================
-- CLEANUP: Remove classification profile from database before dropping
-- ============================================================================
USE ROLE HRZN_DATA_GOVERNOR;
USE WAREHOUSE HRZN_WH;

-- Remove classification profile from database
ALTER DATABASE HRZN_DB UNSET CLASSIFICATION_PROFILE;

-- Drop classification profile
DROP SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE IF EXISTS 
    HRZN_DB.HRZN_SCH.HRZN_STANDARD_CLASSIFICATION_PROFILE;

-- ============================================================================
-- CLEANUP: Drop database (cascades to all schemas, tables, views, functions, stages)
-- ============================================================================
USE ROLE HRZN_DATA_ENGINEER;
DROP DATABASE IF EXISTS HRZN_DB;

-- ============================================================================
-- CLEANUP: Drop roles and warehouse
-- ============================================================================
USE ROLE SECURITYADMIN;
DROP ROLE IF EXISTS HRZN_DATA_GOVERNOR;
DROP ROLE IF EXISTS HRZN_DATA_USER;
DROP ROLE IF EXISTS HRZN_IT_ADMIN;
DROP ROLE IF EXISTS HRZN_DATA_ENGINEER;

USE ROLE SYSADMIN;
DROP WAREHOUSE IF EXISTS HRZN_WH;

-- ============================================================================
-- TEARDOWN COMPLETE
-- ============================================================================
-- All Horizon Lab objects have been removed:
--   ✓ HRZN_DB database and ALL contents (schemas, tables, views, stages, functions)
--   ✓ Classification profile
--   ✓ Custom roles (HRZN_DATA_GOVERNOR, HRZN_DATA_USER, HRZN_IT_ADMIN, HRZN_DATA_ENGINEER)
--   ✓ HRZN_WH warehouse
--
-- Note: Dropping the database automatically removes:
--   - All schemas (HRZN_SCH, CLASSIFIERS, TAG_SCHEMA, SEC_POLICIES_SCHEMA)
--   - All tables (CUSTOMER, CUSTOMER_ORDERS, CUSTOMER_FEEDBACK_REDACTED, ROW_POLICY_MAP)
--   - All views (CUSTOMER_ORDER_ANALYTICS, GOVERNANCE_GAP_ANALYSIS_SIMPLE, etc.)
--   - All stages (SEMANTIC_MODELS)
--   - All functions (INVALID_EMAIL_COUNT data metric function)
--   - All tags, policies, and other database objects
-- ============================================================================
