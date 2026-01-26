/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S | 

Demo:         Horizon Lab - AI Governance Extensions (Natural Language Governance)
Version:      HLab v2.0
Create Date:  Jan 26, 2026
Author:       Severin Gassauer (severin.gassauer@snowflake.com)
Reviewers:    TBD
Copyright(c): 2026 Snowflake Inc. All rights reserved.
****************************************************************************************************

****************************************************************************************************
SUMMARY OF CHANGES
Date(yyyy-mm-dd)    Author              Comments
------------------- ------------------- ------------------------------------------------------------
Jan 26, 2026        Severin Gassauer    Initial AI Governance Extension - NL Governance Queries
***************************************************************************************************/

/*******************************************************************************
 * SECTION 6: NATURAL LANGUAGE GOVERNANCE QUERIES WITH CORTEX CODE
 * 
 * This section demonstrates how to query governance metadata using natural
 * language with Cortex Code (NOT semantic views - those are for business data).
 * 
 * What you'll learn:
 * - Use Cortex Code to ask governance questions in natural language
 * - Query INFORMATION_SCHEMA and ACCOUNT_USAGE views conversationally
 * - Generate compliance reports with AI assistance
 * - Monitor governance metrics without writing SQL
 * 
 * KEY DIFFERENCE FROM SECTION 4:
 * - Section 4: Semantic views for BUSINESS DATA (customer orders, sales, etc.)
 * - Section 6: Cortex Code for GOVERNANCE METADATA (policies, tags, grants, etc.)
 * - You don't need semantic views over system tables!
 *******************************************************************************/

USE ROLE HRZN_DATA_GOVERNOR;
USE WAREHOUSE HRZN_WH;
USE DATABASE HRZN_DB;
USE SCHEMA HRZN_SCH;

-- ============================================================================
-- 6.1: VERIFY GOVERNANCE METADATA IS AVAILABLE
-- ============================================================================

-- Test 1: Check tag references data
SELECT 
    TAG_NAME,
    TAG_VALUE,
    OBJECT_NAME,
    DOMAIN,
    COUNT(*) as count
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE OBJECT_DATABASE = 'HRZN_DB'
GROUP BY TAG_NAME, TAG_VALUE, OBJECT_NAME, DOMAIN
LIMIT 10;

-- Test 2: Check policy references
SELECT 
    POLICY_KIND,
    POLICY_NAME,
    REF_ENTITY_NAME,
    REF_COLUMN_NAME,
    POLICY_STATUS
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
WHERE POLICY_DB = 'HRZN_DB'
LIMIT 10;

-- Test 3: Check masking policies
SHOW MASKING POLICIES IN SCHEMA HRZN_DB.TAG_SCHEMA;

/*******************************************************************************
CORTEX CODE - ASK GOVERNANCE QUESTIONS IN NATURAL LANGUAGE
 
 Open Snowsight, click the Cortex Code icon (✨), and try these questions:
 
 COMPLIANCE & AUDIT QUESTIONS:
 -------------------------------
 1. "Which tables have PII but no masking policy?"
 2. "Who accessed PII data in the last 7 days?"
 3. "What policies are applied to the CUSTOMER table?"
 4. "List all users who accessed sensitive data this month"
 
 USAGE & ADOPTION:
 -----------------
 5. "Who are the top users accessing sensitive data?"
 6. "How many Cortex Analyst queries ran this week?"
 
 AI ASSET GOVERNANCE:
 --------------------
 7. "Which semantic views exist in HRZN_DB?"
 8. "Show all tables accessed by CUSTOMER_ORDER_ANALYTICS semantic view"
 
 TAG MANAGEMENT:
 ---------------
 9. "What tags are applied to the CUSTOMER table?"
 10. "List all tables tagged with PII_COL"
 
 📌 TIP: Cortex Code understands INFORMATION_SCHEMA and ACCOUNT_USAGE views.
         It will write SQL queries to answer your governance questions automatically!
         
 📌 NO SEMANTIC VIEW NEEDED: Unlike business analytics (Section 4), governance
    queries work directly against system views without semantic models!
*******************************************************************************/

-- ============================================================================
-- 6.3: MANUAL SQL VERSIONS OF GOVERNANCE QUESTIONS
-- ============================================================================
-- These are examples of SQL queries that Cortex Code would generate automatically
-- You can run these directly, or ask Cortex Code to generate similar queries

-- Q: Which tables have PII but no masking policy?
WITH pii_tables AS (
    SELECT DISTINCT 
        OBJECT_DATABASE,
        OBJECT_SCHEMA,
        OBJECT_NAME,
        TAG_VALUE as pii_type
    FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
    WHERE TAG_NAME = 'SEMANTIC_CATEGORY'
      AND TAG_VALUE IN ('EMAIL', 'SSN', 'PHONE_NUMBER', 'CREDIT_CARD', 'NAME')
      AND DOMAIN = 'COLUMN'
      AND OBJECT_DATABASE = 'HRZN_DB'
),
masked_tables AS (
    SELECT DISTINCT 
        SPLIT_PART(REF_ENTITY_NAME, '.', 1) as db,
        SPLIT_PART(REF_ENTITY_NAME, '.', 2) as schema,
        SPLIT_PART(REF_ENTITY_NAME, '.', 3) as table_name
    FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
    WHERE POLICY_KIND = 'MASKING_POLICY'
      AND POLICY_STATUS = 'ACTIVE'
)
SELECT 
    p.OBJECT_DATABASE || '.' || p.OBJECT_SCHEMA || '.' || p.OBJECT_NAME as full_table_name,
    LISTAGG(DISTINCT p.pii_type, ', ') as pii_types,
    'HIGH RISK: No masking policy' as governance_status
FROM pii_tables p
LEFT JOIN masked_tables m 
    ON p.OBJECT_DATABASE = m.db 
    AND p.OBJECT_SCHEMA = m.schema
    AND p.OBJECT_NAME = m.table_name
WHERE m.table_name IS NULL
GROUP BY p.OBJECT_DATABASE, p.OBJECT_SCHEMA, p.OBJECT_NAME;

-- Q: Who accessed PII data in the last 7 days?
SELECT 
    qh.USER_NAME,
    qh.ROLE_NAME,
    qh.START_TIME::DATE as access_date,
    COUNT(DISTINCT qh.QUERY_ID) as pii_query_count,
    LISTAGG(DISTINCT f.value:objectName::STRING, ', ') as pii_tables_accessed
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
JOIN SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah ON qh.QUERY_ID = ah.QUERY_ID,
LATERAL FLATTEN(input => ah.DIRECT_OBJECTS_ACCESSED) f
WHERE f.value:objectName::STRING IN (
    SELECT DISTINCT OBJECT_DATABASE || '.' || OBJECT_SCHEMA || '.' || OBJECT_NAME
    FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
    WHERE TAG_NAME = 'SEMANTIC_CATEGORY'
      AND TAG_VALUE IN ('EMAIL', 'SSN', 'PHONE_NUMBER', 'CREDIT_CARD')
      AND OBJECT_DATABASE = 'HRZN_DB'
)
AND qh.START_TIME >= DATEADD(day, -7, CURRENT_TIMESTAMP())
GROUP BY qh.USER_NAME, qh.ROLE_NAME, qh.START_TIME::DATE
ORDER BY access_date DESC, pii_query_count DESC;

-- Q: What is the governance coverage by schema?
WITH table_inventory AS (
    SELECT 
        TABLE_SCHEMA,
        COUNT(*) as total_tables,
        SUM(CASE WHEN TABLE_TYPE = 'BASE TABLE' THEN 1 ELSE 0 END) as base_tables,
        SUM(CASE WHEN TABLE_TYPE = 'VIEW' THEN 1 ELSE 0 END) as views
    FROM HRZN_DB.INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = 'HRZN_SCH'
    GROUP BY TABLE_SCHEMA
),
governance_stats AS (
    SELECT 
        OBJECT_SCHEMA,
        COUNT(DISTINCT CASE WHEN tr.DOMAIN = 'TABLE' THEN tr.OBJECT_NAME END) as tagged_tables,
        COUNT(DISTINCT CASE WHEN tr.DOMAIN = 'COLUMN' THEN tr.OBJECT_NAME END) as tables_with_tagged_columns,
        COUNT(DISTINCT CASE WHEN pr.REF_ENTITY_DOMAIN = 'TABLE' 
                            THEN SPLIT_PART(pr.REF_ENTITY_NAME, '.', 3) END) as protected_tables
    FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
    FULL OUTER JOIN SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES pr
        ON tr.OBJECT_NAME = SPLIT_PART(pr.REF_ENTITY_NAME, '.', 3)
        AND tr.OBJECT_SCHEMA = SPLIT_PART(pr.REF_ENTITY_NAME, '.', 2)
    WHERE tr.OBJECT_DATABASE = 'HRZN_DB' OR SPLIT_PART(pr.REF_ENTITY_NAME, '.', 1) = 'HRZN_DB'
    GROUP BY OBJECT_SCHEMA
)
SELECT 
    ti.TABLE_SCHEMA,
    ti.total_tables,
    ti.base_tables,
    ti.views,
    COALESCE(gs.tagged_tables, 0) as tagged_tables,
    COALESCE(gs.protected_tables, 0) as protected_tables,
    ROUND(COALESCE(gs.tagged_tables, 0) * 100.0 / NULLIF(ti.total_tables, 0), 1) as pct_tagged,
    ROUND(COALESCE(gs.protected_tables, 0) * 100.0 / NULLIF(ti.total_tables, 0), 1) as pct_protected,
    CASE 
        WHEN COALESCE(gs.protected_tables, 0) * 100.0 / NULLIF(ti.total_tables, 0) >= 80 THEN 'Excellent'
        WHEN COALESCE(gs.protected_tables, 0) * 100.0 / NULLIF(ti.total_tables, 0) >= 60 THEN 'Good'
        WHEN COALESCE(gs.protected_tables, 0) * 100.0 / NULLIF(ti.total_tables, 0) >= 40 THEN 'Fair'
        ELSE 'Needs Improvement'
    END as governance_grade
FROM table_inventory ti
LEFT JOIN governance_stats gs ON ti.TABLE_SCHEMA = gs.OBJECT_SCHEMA;

-- Q: Show tag distribution across objects
SELECT 
    TAG_NAME,
    TAG_VALUE,
    DOMAIN as object_type,
    COUNT(*) as tagged_objects,
    COUNT(DISTINCT OBJECT_NAME) as unique_objects
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE OBJECT_DATABASE = 'HRZN_DB'
GROUP BY TAG_NAME, TAG_VALUE, DOMAIN
ORDER BY tagged_objects DESC;

-- Q: What types of policies are applied?
SELECT 
    POLICY_KIND,
    POLICY_STATUS,
    COUNT(DISTINCT POLICY_NAME) as policy_count,
    COUNT(DISTINCT REF_ENTITY_NAME) as protected_objects,
    COUNT(DISTINCT REF_COLUMN_NAME) as protected_columns
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
WHERE SPLIT_PART(REF_ENTITY_NAME, '.', 1) = 'HRZN_DB'
GROUP BY POLICY_KIND, POLICY_STATUS
ORDER BY policy_count DESC;

-- Q: Who are the top users accessing sensitive data?
SELECT 
    qh.USER_NAME,
    qh.ROLE_NAME,
    COUNT(DISTINCT qh.QUERY_ID) as total_queries,
    COUNT(DISTINCT qh.START_TIME::DATE) as active_days,
    AVG(qh.TOTAL_ELAPSED_TIME)/1000 as avg_query_seconds,
    SUM(qh.BYTES_SCANNED)/(1024*1024*1024) as total_gb_scanned,
    MIN(qh.START_TIME) as first_access,
    MAX(qh.START_TIME) as last_access
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
WHERE (qh.QUERY_TEXT ILIKE '%HRZN_DB.HRZN_SCH.CUSTOMER%'
   OR qh.QUERY_TEXT ILIKE '%HRZN_DB.HRZN_SCH.CUSTOMER_ORDERS%')
  AND qh.START_TIME >= DATEADD(day, -30, CURRENT_TIMESTAMP())
  AND qh.EXECUTION_STATUS = 'SUCCESS'
GROUP BY qh.USER_NAME, qh.ROLE_NAME
ORDER BY total_queries DESC
LIMIT 10;