
/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S | 
|
|Demo:         Horizon Lab (Data Governor / Steward Persona)
|Version:      HLab v2.0
|Create Date:  Apr 17, 2024
|Author:       Ravi Kumar
|Reviewers:    Ben Weiss, Susan Devitt
|Contributor:  Severin Gassauer (severin.gassauer@snowflake.com)
|Copyright(c): 2026 Snowflake Inc. All rights reserved.
|****************************************************************************************************
|
|****************************************************************************************************
|SUMMARY OF CHANGES
|Date(yyyy-mm-dd)    Author              Comments
|------------------- ------------------- ------------------------------------------------------------
|Apr 17, 2024        Ravi Kumar          Initial Lab
|Jan 26, 2026        Severin Gassauer    Updated for v2.0 - Unified DATA_CLASSIFICATION taxonomy
|***************************************************************************************************/


/*************************************************/
/*************************************************/
/* D A T A      U S E R      R O L E */
/*************************************************/
/*************************************************/
USE ROLE HRZN_DATA_USER;
USE WAREHOUSE HRZN_WH;
USE DATABASE HRZN_DB;
USE SCHEMA HRZN_SCH;

-- Now, Let's look at the customer details
SELECT FIRST_NAME, LAST_NAME, STREET_ADDRESS, STATE, CITY, ZIP, PHONE_NUMBER, EMAIL, SSN, BIRTHDATE, CREDITCARD
FROM HRZN_DB.HRZN_SCH.CUSTOMER
SAMPLE (100 ROWS);

-- there is a lot of PII and sensitive data that needs to be protected
-- Further, there is no understanding of what fields contain the sensitive data.
-- To set this straight, we need to ensure that the right fields are classified and tagged properly.
-- Further, we need to mask PII and other sensitive data.





/*************************************************/
/*************************************************/
/* D A T A      G O V E R N O R      R O L E */
/*************************************************/
/*************************************************/
USE ROLE HRZN_DATA_GOVERNOR;

/*----------------------------------------------------------------------------------
Step - Sensitive Data Classification with Tag Mapping

 In some cases, you may not know if there is sensitive data in a table.
 Snowflake Horizon provides the capability to automatically detect
 sensitive information and apply relevant tags. 

 In this lab, we'll use a CLASSIFICATION_PROFILE with tag_map to:
 1. Automatically detect PII using AI classification
 2. Map detected PII to our custom DATA_CLASSIFICATION tag
 3. Enable tag propagation to downstream tables

 Classification Levels in DATA_CLASSIFICATION tag:
 - PII: Personal identifiers (email, SSN) - highest protection
 - RESTRICTED: Sensitive personal data (phone, birthdate)
 - SENSITIVE: Personal information (name, address)
 - INTERNAL: Business data (job, company)
 - PUBLIC: Non-sensitive identifiers - lowest protection
----------------------------------------------------------------------------------*/

/****************************************************/
-- 1. CREATE TAG SCHEMA AND DATA_CLASSIFICATION TAG
/****************************************************/
USE ROLE HRZN_DATA_GOVERNOR;
CREATE SCHEMA IF NOT EXISTS HRZN_DB.TAG_SCHEMA;
USE SCHEMA HRZN_DB.TAG_SCHEMA;

-- Create enterprise classification tag with propagation enabled
CREATE OR REPLACE TAG HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION 
    ALLOWED_VALUES 'PII', 'RESTRICTED', 'SENSITIVE', 'INTERNAL', 'PUBLIC'
    COMMENT = 'Enterprise data classification with AI automation and propagation'
    PROPAGATE = ON_DEPENDENCY_AND_DATA_MOVEMENT;

/****************************************************/
-- 2. CREATE CLASSIFICATION PROFILE WITH TAG MAP
/****************************************************/
USE ROLE SYSADMIN;

CREATE OR REPLACE SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE 
    HRZN_DB.HRZN_SCH.HRZN_STANDARD_CLASSIFICATION_PROFILE(
    {
      'minimum_object_age_for_classification_days': 0,
      'maximum_classification_validity_days': 90,
      'auto_tag': true,
      'classify_views': true,
      'tag_map': {
        'column_tag_map': [
          {
            'tag_name': 'HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION',
            'tag_value': 'PII',
            'semantic_categories': [
              'EMAIL', 
              'US_SOCIAL_SECURITY_NUMBER',
              'NATIONAL_IDENTIFIER',
              'US_BANK_ACCOUNT_NUMBER',
              'CREDIT_CARD_NUMBER'
            ]
          },
          {
            'tag_name': 'HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION',
            'tag_value': 'RESTRICTED',
            'semantic_categories': [
              'PHONE_NUMBER',
              'DATE_OF_BIRTH'
            ]
          },
          {
            'tag_name': 'HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION',
            'tag_value': 'SENSITIVE',
            'semantic_categories': [
              'NAME',
              'STREET_ADDRESS',
              'CITY',
              'US_STATE',
              'ZIP_CODE'
            ]
          },
          {
            'tag_name': 'HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION',
            'tag_value': 'INTERNAL',
            'semantic_categories': [
              'JOB_TITLE',
              'OCCUPATION',
              'COMPANY'
            ]
          }
        ]
      }
    });

/****************************************************/
-- 3. APPLY CLASSIFICATION PROFILE AND CLASSIFY
/****************************************************/
USE ROLE HRZN_DATA_GOVERNOR;

-- Apply classification profile to the database
ALTER DATABASE HRZN_DB 
    SET CLASSIFICATION_PROFILE = 'HRZN_DB.HRZN_SCH.HRZN_STANDARD_CLASSIFICATION_PROFILE';

-- Run AI classification on CUSTOMER table
CALL SYSTEM$CLASSIFY(
    'HRZN_DB.HRZN_SCH.CUSTOMER',
    'HRZN_DB.HRZN_SCH.HRZN_STANDARD_CLASSIFICATION_PROFILE'
);

-- View all tags applied (system + custom)
SELECT TAG_DATABASE, TAG_SCHEMA, OBJECT_NAME, COLUMN_NAME, TAG_NAME, TAG_VALUE
FROM TABLE(
  HRZN_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
    'HRZN_DB.HRZN_SCH.CUSTOMER',
    'table'
))
ORDER BY TAG_NAME, COLUMN_NAME;

-- View only DATA_CLASSIFICATION tags (the ones that will propagate)
SELECT 
    COLUMN_NAME,
    TAG_VALUE as CLASSIFICATION_LEVEL
FROM TABLE(
    INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
        'HRZN_DB.HRZN_SCH.CUSTOMER', 
        'table'
    )
)
WHERE TAG_NAME = 'DATA_CLASSIFICATION'
ORDER BY 
    CASE TAG_VALUE 
        WHEN 'PII' THEN 1
        WHEN 'RESTRICTED' THEN 2
        WHEN 'SENSITIVE' THEN 3
        WHEN 'INTERNAL' THEN 4
        WHEN 'PUBLIC' THEN 5
    END,
    COLUMN_NAME;

/*******************************************************************************
 * KEY OBSERVATION: Classification with Tag Mapping
 * 
 * The classification profile applied TWO types of tags:
 * 1. System tags (SEMANTIC_CATEGORY, PRIVACY_CATEGORY) - don't propagate
 * 2. DATA_CLASSIFICATION tag - DOES propagate to downstream tables!
 * 
 * This BYOT (Bring Your Own Tags) pattern ensures governance policies 
 * automatically flow to derived datasets.
 *******************************************************************************/

/****************************************************/
-- 4. CUSTOM CLASSIFICATION FOR CREDIT CARDS
/****************************************************/
USE SCHEMA HRZN_DB.CLASSIFIERS;

-- Create a custom classifier for credit card patterns
CREATE OR REPLACE SNOWFLAKE.DATA_PRIVACY.CUSTOM_CLASSIFIER CREDITCARD();

SHOW SNOWFLAKE.DATA_PRIVACY.CUSTOM_CLASSIFIER;

-- Add regex patterns for different credit card types
CALL creditcard!add_regex('MC_PAYMENT_CARD','IDENTIFIER','^(?:5[1-5][0-9]{2}|222[1-9]|22[3-9][0-9]|2[3-6][0-9]{2}|27[01][0-9]|2720)[0-9]{12}$');
CALL creditcard!add_regex('AMX_PAYMENT_CARD','IDENTIFIER','^3[4-7][0-9]{13}$');

SELECT creditcard!list();

-- Verify credit card data exists
SELECT CREDITCARD 
FROM HRZN_DB.HRZN_SCH.CUSTOMER 
WHERE CREDITCARD REGEXP '^3[4-7][0-9]{13}$'
LIMIT 5;

-- Re-classify with custom classifier (without profile, using options)
CALL SYSTEM$CLASSIFY(
    'HRZN_DB.HRZN_SCH.CUSTOMER',
    {'custom_classifiers': ['HRZN_DB.CLASSIFIERS.CREDITCARD'], 'auto_tag': true}
);

-- Check credit card classification
SELECT SYSTEM$GET_TAG('snowflake.core.semantic_category','HRZN_DB.HRZN_SCH.CUSTOMER.CREDITCARD','column');

/****************************************************/
-- 5. CREATE TAG-BASED MASKING POLICIES (Multi-Type)
/****************************************************/
USE ROLE HRZN_DATA_GOVERNOR;
USE SCHEMA HRZN_DB.TAG_SCHEMA;

/*******************************************************************************
 * BEST PRACTICE: Multi-Type Masking Policies
 * 
 * Snowflake masking policies are data-type specific. A STRING policy only works
 * on STRING columns. For comprehensive protection, create one policy per data type
 * and attach all to the same tag.
 * 
 * OPT-IN LOGIC: Customers who have opted in (OPTIN='Y') have consented to data
 * sharing. Their data may be visible to authorized roles for analytics purposes.
 *******************************************************************************/

-- Create opt-in lookup table for masking decisions
CREATE OR REPLACE TABLE HRZN_DB.TAG_SCHEMA.CUSTOMER_CONSENT_MAP AS
SELECT DISTINCT ID as CUSTOMER_ID, OPTIN 
FROM HRZN_DB.HRZN_SCH.CUSTOMER;

GRANT SELECT ON TABLE HRZN_DB.TAG_SCHEMA.CUSTOMER_CONSENT_MAP TO ROLE HRZN_DATA_USER;
GRANT SELECT ON TABLE HRZN_DB.TAG_SCHEMA.CUSTOMER_CONSENT_MAP TO ROLE HRZN_IT_ADMIN;

-- ============================================================================
-- STRING MASKING POLICY (for VARCHAR columns)
-- ============================================================================
CREATE OR REPLACE MASKING POLICY HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION_MASK_STRING
AS (VAL STRING) 
RETURNS STRING ->
CASE
    -- Governors and admins always see full data
    WHEN CURRENT_ROLE() IN ('HRZN_DATA_GOVERNOR', 'ACCOUNTADMIN')
    THEN VAL
    
    -- PII: Full redaction for non-governors (regardless of opt-in)
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'PII'
    THEN '***PII-REDACTED***'
    
    -- RESTRICTED: Partial masking - show last 4 characters
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'RESTRICTED'
    THEN CONCAT('***-', RIGHT(VAL, 4))
    
    -- SENSITIVE: SHA2 hash for pseudonymization
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'SENSITIVE'
    THEN SHA2(VAL, 256)
    
    -- INTERNAL and PUBLIC: Visible to all
    ELSE VAL
END;

-- ============================================================================
-- NUMBER MASKING POLICY (for FLOAT, INTEGER, NUMBER columns)
-- ============================================================================
CREATE OR REPLACE MASKING POLICY HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION_MASK_NUMBER
AS (VAL NUMBER) 
RETURNS NUMBER ->
CASE
    -- Governors and admins always see full data
    WHEN CURRENT_ROLE() IN ('HRZN_DATA_GOVERNOR', 'ACCOUNTADMIN')
    THEN VAL
    
    -- PII: Return NULL for numeric PII (like SSN stored as number)
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'PII'
    THEN NULL
    
    -- RESTRICTED: Round to reduce precision
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'RESTRICTED'
    THEN ROUND(VAL, -2)
    
    -- SENSITIVE: Return hash as number (deterministic for joins)
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'SENSITIVE'
    THEN ABS(HASH(VAL))
    
    -- INTERNAL and PUBLIC: Visible to all
    ELSE VAL
END;

-- ============================================================================
-- DATE MASKING POLICY (for DATE columns)
-- ============================================================================
CREATE OR REPLACE MASKING POLICY HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION_MASK_DATE
AS (VAL DATE) 
RETURNS DATE ->
CASE
    -- Governors and admins always see full data
    WHEN CURRENT_ROLE() IN ('HRZN_DATA_GOVERNOR', 'ACCOUNTADMIN')
    THEN VAL
    
    -- PII: Return NULL for date-based PII
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'PII'
    THEN NULL
    
    -- RESTRICTED: Show only year (first day of year)
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'RESTRICTED'
    THEN DATE_TRUNC('YEAR', VAL)
    
    -- SENSITIVE: Generalize to first of month
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'SENSITIVE'
    THEN DATE_TRUNC('MONTH', VAL)
    
    -- INTERNAL and PUBLIC: Visible to all
    ELSE VAL
END;

-- ============================================================================
-- TIMESTAMP MASKING POLICY (for TIMESTAMP columns)
-- ============================================================================
CREATE OR REPLACE MASKING POLICY HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION_MASK_TIMESTAMP
AS (VAL TIMESTAMP) 
RETURNS TIMESTAMP ->
CASE
    -- Governors and admins always see full data
    WHEN CURRENT_ROLE() IN ('HRZN_DATA_GOVERNOR', 'ACCOUNTADMIN')
    THEN VAL
    
    -- PII: Return NULL for timestamp-based PII
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'PII'
    THEN NULL
    
    -- RESTRICTED: Show only date portion (midnight)
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'RESTRICTED'
    THEN DATE_TRUNC('DAY', VAL)
    
    -- SENSITIVE: Generalize to first of month
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'SENSITIVE'
    THEN DATE_TRUNC('MONTH', VAL)
    
    -- INTERNAL and PUBLIC: Visible to all
    ELSE VAL
END;

-- ============================================================================
-- ATTACH ALL POLICIES TO THE DATA_CLASSIFICATION TAG
-- ============================================================================
-- Each data type gets its own policy attached to the same tag
ALTER TAG HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION 
    SET MASKING POLICY HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION_MASK_STRING;

ALTER TAG HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION 
    SET MASKING POLICY HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION_MASK_NUMBER;

ALTER TAG HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION 
    SET MASKING POLICY HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION_MASK_DATE;

ALTER TAG HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION 
    SET MASKING POLICY HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION_MASK_TIMESTAMP;

/*******************************************************************************
 * KEY BENEFITS: Production-Ready Multi-Type Masking
 * 
 * 1. TYPE SAFETY: Each data type has appropriate masking logic
 *    - STRING: Redaction, partial masking, or hashing
 *    - NUMBER: NULL, rounding, or deterministic hash
 *    - DATE/TIMESTAMP: NULL or date truncation for k-anonymity
 * 
 * 2. CLASSIFICATION LEVELS: Consistent across all types
 *    - PII: Maximum protection (redact/NULL)
 *    - RESTRICTED: Partial visibility (last 4 chars, rounded, year only)
 *    - SENSITIVE: Pseudonymized (hash, month truncation)
 *    - INTERNAL/PUBLIC: Full visibility
 * 
 * 3. AUTOMATIC APPLICATION: Any column tagged with DATA_CLASSIFICATION
 *    automatically gets the appropriate masking policy based on its data type
 * 
 * 4. FUTURE-PROOF: Add new tables/columns - just tag them!
 *******************************************************************************/

/****************************************************/
-- 5b. OPT-IN AWARE ROW ACCESS POLICY
/****************************************************/
/*******************************************************************************
 * OPT-IN GOVERNANCE PATTERN
 * 
 * Masking policies protect column values but operate on individual values.
 * For row-level opt-in logic (show/hide entire customer records based on consent),
 * combine masking with a row access policy.
 * 
 * This pattern demonstrates:
 * - Customers who opted OUT (OPTIN='N') are hidden from DATA_USER role
 * - Customers who opted IN (OPTIN='Y') are visible (but still masked per policy)
 * - Governors see all customers regardless of opt-in status
 *******************************************************************************/

CREATE OR REPLACE ROW ACCESS POLICY HRZN_DB.TAG_SCHEMA.CUSTOMER_OPTIN_POLICY
    AS (OPTIN_STATUS STRING) RETURNS BOOLEAN ->
    CASE
        -- Governors and admins see all records
        WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN', 'HRZN_DATA_ENGINEER', 'HRZN_DATA_GOVERNOR', 'HRZN_IT_ADMIN')
        THEN TRUE
        -- Data users only see opted-in customers
        WHEN CURRENT_ROLE() = 'HRZN_DATA_USER' AND OPTIN_STATUS = 'Y'
        THEN TRUE
        -- Hide non-opted-in records from data users
        ELSE FALSE
    END;

-- Apply opt-in policy to CUSTOMER table
ALTER TABLE HRZN_DB.HRZN_SCH.CUSTOMER
    ADD ROW ACCESS POLICY HRZN_DB.TAG_SCHEMA.CUSTOMER_OPTIN_POLICY ON (OPTIN);

/****************************************************/
-- 6. TEST MASKING AND OPT-IN WITH DIFFERENT ROLES
/****************************************************/

-- As HRZN_DATA_GOVERNOR: Full visibility (all records, all data)
USE ROLE HRZN_DATA_GOVERNOR;
SELECT 
    ID,              -- PUBLIC
    FIRST_NAME,      -- SENSITIVE
    EMAIL,           -- PII
    SSN,             -- PII
    PHONE_NUMBER,    -- RESTRICTED
    BIRTHDATE,       -- RESTRICTED
    COMPANY,         -- INTERNAL
    OPTIN            -- Shows consent status
FROM HRZN_DB.HRZN_SCH.CUSTOMER
LIMIT 10;

-- Count all customers vs opted-in customers (Governor sees all)
SELECT 
    COUNT(*) as total_customers,
    SUM(CASE WHEN OPTIN = 'Y' THEN 1 ELSE 0 END) as opted_in_customers
FROM HRZN_DB.HRZN_SCH.CUSTOMER;

-- As HRZN_DATA_USER: Multi-level masking + ONLY opted-in customers visible
USE ROLE HRZN_DATA_USER;
SELECT 
    ID,              -- PUBLIC: Visible
    FIRST_NAME,      -- SENSITIVE: Hashed
    EMAIL,           -- PII: Fully redacted
    SSN,             -- PII: Fully redacted
    PHONE_NUMBER,    -- RESTRICTED: Partial mask (***-1234)
    BIRTHDATE,       -- RESTRICTED: Partial mask (***-0590)
    COMPANY,         -- INTERNAL: Visible
    OPTIN            -- All rows shown have OPTIN='Y' due to row access policy
FROM HRZN_DB.HRZN_SCH.CUSTOMER
LIMIT 10;

-- Count shows only opted-in customers are visible to DATA_USER
SELECT COUNT(*) as visible_customers FROM HRZN_DB.HRZN_SCH.CUSTOMER;

/*******************************************************************************
 * KEY OBSERVATION: Layered Governance
 * 
 * HRZN_DATA_USER sees:
 * 1. ROW FILTERING: Only customers with OPTIN='Y' (consent given)
 * 2. COLUMN MASKING: PII redacted, RESTRICTED partial, SENSITIVE hashed
 * 
 * This demonstrates defense-in-depth:
 * - Row access policy controls WHO can see WHICH records
 * - Masking policy controls HOW data appears when visible
 *******************************************************************************/

USE ROLE HRZN_DATA_GOVERNOR;

/****************************************************/
-- 7. TAG PROPAGATION TO DOWNSTREAM TABLES
/****************************************************/

-- Create derived table
USE ROLE HRZN_DATA_ENGINEER;
CREATE TABLE HRZN_DB.HRZN_SCH.CUSTOMER_COPY AS 
SELECT * FROM HRZN_DB.HRZN_SCH.CUSTOMER;

-- View propagated tags
USE ROLE HRZN_DATA_GOVERNOR;
SELECT 
    COLUMN_NAME,
    TAG_VALUE as CLASSIFICATION_LEVEL
FROM TABLE(
    INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
        'HRZN_DB.HRZN_SCH.CUSTOMER_COPY', 
        'table'
    )
)
WHERE TAG_NAME = 'DATA_CLASSIFICATION'
ORDER BY 
    CASE TAG_VALUE 
        WHEN 'PII' THEN 1
        WHEN 'RESTRICTED' THEN 2
        WHEN 'SENSITIVE' THEN 3
        WHEN 'INTERNAL' THEN 4
        WHEN 'PUBLIC' THEN 5
    END,
    COLUMN_NAME;

/*******************************************************************************
 * 🎯 KEY OBSERVATION: Tags Automatically Propagated!
 * 
 * The CUSTOMER_COPY table inherited ALL classification tags from CUSTOMER.
 * Masking policies apply automatically - no manual work needed!
 *******************************************************************************/

-- Test masking on derived table
USE ROLE HRZN_DATA_USER;
SELECT * FROM HRZN_DB.HRZN_SCH.CUSTOMER_COPY LIMIT 5;

USE ROLE HRZN_DATA_GOVERNOR;

/****************************************************/
-- 8. ROW ACCESS POLICIES (State-Based Filtering)
/****************************************************/

/*----------------------------------------------------------------------------------
Step- Row-Access Policies

A row access policy is a schema-level object that determines whether a given row 
in a table or view can be viewed from SELECT, UPDATE, DELETE, and MERGE statements.

Within our Customer table, the users with HRZN_DATA_USER should only see Customers 
who are based in Massachusetts (MA).

NOTE: Multiple row access policies on the same table are ANDed together.
We'll first drop the opt-in policy to demonstrate state-based filtering in isolation.
----------------------------------------------------------------------------------*/

-- Drop the opt-in policy to demonstrate state-based filtering cleanly
ALTER TABLE HRZN_DB.HRZN_SCH.CUSTOMER
    DROP ROW ACCESS POLICY HRZN_DB.TAG_SCHEMA.CUSTOMER_OPTIN_POLICY;

-- First, unset STATE tag to allow it to be used in WHERE clause
ALTER TABLE HRZN_DB.HRZN_SCH.CUSTOMER MODIFY COLUMN STATE UNSET TAG HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION;

/*************************************************/
/* D A T A      U S E R      R O L E */
/*************************************************/
USE ROLE HRZN_DATA_USER;
SELECT FIRST_NAME, STREET_ADDRESS, STATE, PHONE_NUMBER, EMAIL, JOB, COMPANY 
FROM HRZN_DB.HRZN_SCH.CUSTOMER
LIMIT 10;

/*************************************************/
/* D A T A      G O V E R N O R      R O L E */
/*************************************************/
USE ROLE HRZN_DATA_GOVERNOR;

-- View the mapping table
SELECT * FROM HRZN_DB.TAG_SCHEMA.ROW_POLICY_MAP; 

-- Create row access policy
CREATE OR REPLACE ROW ACCESS POLICY HRZN_DB.TAG_SCHEMA.CUSTOMER_STATE_RESTRICTIONS
    AS (STATE STRING) RETURNS BOOLEAN ->
       CURRENT_ROLE() IN ('ACCOUNTADMIN','HRZN_DATA_ENGINEER','HRZN_DATA_GOVERNOR')
        OR EXISTS 
            (
            SELECT rp.ROLE
                FROM HRZN_DB.TAG_SCHEMA.ROW_POLICY_MAP rp
            WHERE 1=1
                AND rp.ROLE = CURRENT_ROLE()
                AND rp.STATE_VISIBILITY = STATE
            )
COMMENT = 'Policy to limit rows returned based on mapping table of ROLE and STATE: governance.row_policy_map';

-- Apply the Row Access Policy
ALTER TABLE HRZN_DB.HRZN_SCH.CUSTOMER
    ADD ROW ACCESS POLICY HRZN_DB.TAG_SCHEMA.CUSTOMER_STATE_RESTRICTIONS ON (STATE);

/*************************************************/
/* D A T A      U S E R      R O L E */
/*************************************************/
USE ROLE HRZN_DATA_USER;
SELECT FIRST_NAME, STREET_ADDRESS, STATE, PHONE_NUMBER, EMAIL, JOB, COMPANY 
FROM HRZN_DB.HRZN_SCH.CUSTOMER;

USE ROLE HRZN_DATA_GOVERNOR;

/****************************************************/
-- 9. AGGREGATION POLICIES
/****************************************************/

/*----------------------------------------------------------------------------------
Step - Aggregation Policies

 An Aggregation Policy is a schema-level object that controls what type of
 query can access data from a table or view. Queries must aggregate data into 
 groups of a minimum size to return results, preventing queries from returning 
 individual records.
----------------------------------------------------------------------------------*/

CREATE OR REPLACE AGGREGATION POLICY HRZN_DB.TAG_SCHEMA.aggregation_policy
  AS () RETURNS AGGREGATION_CONSTRAINT ->
    CASE
      WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN','HRZN_DATA_ENGINEER','HRZN_DATA_GOVERNOR')
      THEN NO_AGGREGATION_CONSTRAINT()  
      ELSE AGGREGATION_CONSTRAINT(MIN_GROUP_SIZE => 100)
    END;

ALTER TABLE HRZN_DB.HRZN_SCH.CUSTOMER_ORDERS
    SET AGGREGATION POLICY HRZN_DB.TAG_SCHEMA.aggregation_policy;

/*************************************************/
/* D A T A      U S E R      R O L E */
/*************************************************/
USE ROLE HRZN_DATA_USER;

-- This will fail - can't SELECT * with aggregation policy
SELECT TOP 10 * FROM HRZN_DB.HRZN_SCH.CUSTOMER_ORDERS;

-- This works - aggregates over 100 rows
SELECT ORDER_CURRENCY, SUM(ORDER_AMOUNT) 
FROM HRZN_DB.HRZN_SCH.CUSTOMER_ORDERS 
GROUP BY ORDER_CURRENCY;

-- Join with customer data
SELECT 
    cl.state,
    cl.city,
    COUNT(oh.order_id) AS count_order,
    SUM(oh.order_amount) AS order_total
FROM HRZN_DB.HRZN_SCH.CUSTOMER_ORDERS oh
JOIN HRZN_DB.HRZN_SCH.CUSTOMER cl
    ON oh.customer_id = cl.id
GROUP BY ALL
ORDER BY order_total DESC;

/*************************************************/
/* D A T A      G O V E R N O R      R O L E */
/*************************************************/
USE ROLE HRZN_DATA_GOVERNOR;
USE SCHEMA HRZN_DB.TAG_SCHEMA;

SELECT 
    cl.company,
    cl.job,
    COUNT(oh.order_id) AS count_order,
    SUM(oh.order_amount) AS order_total
FROM HRZN_DB.HRZN_SCH.CUSTOMER_ORDERS oh
JOIN HRZN_DB.HRZN_SCH.CUSTOMER cl
    ON oh.customer_id = cl.id
GROUP BY ALL
ORDER BY order_total DESC;

/****************************************************/
-- 10. PROJECTION POLICIES
/****************************************************/
/*----------------------------------------------------------------------------------
Step - Projection Policies

  A projection policy is a schema-level object that defines whether a column 
  can be projected in the output of a SQL query result. A column with a 
  projection policy assigned to it is said to be projection constrained.
----------------------------------------------------------------------------------*/

-- Unset ZIP tag first
ALTER TABLE HRZN_DB.HRZN_SCH.CUSTOMER MODIFY COLUMN ZIP UNSET TAG HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION;

-- Create projection policy
CREATE OR REPLACE PROJECTION POLICY HRZN_DB.TAG_SCHEMA.projection_policy
  AS () RETURNS PROJECTION_CONSTRAINT -> 
  CASE
    WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN','HRZN_DATA_ENGINEER', 'HRZN_DATA_GOVERNOR')
    THEN PROJECTION_CONSTRAINT(ALLOW => true)
    ELSE PROJECTION_CONSTRAINT(ALLOW => false)
  END;

-- Apply projection policy to ZIP column
ALTER TABLE HRZN_DB.HRZN_SCH.CUSTOMER
 MODIFY COLUMN ZIP
 SET PROJECTION POLICY HRZN_DB.TAG_SCHEMA.projection_policy;

/*************************************************/
/* D A T A      U S E R      R O L E */
/*************************************************/
USE ROLE HRZN_DATA_USER;

-- This fails - ZIP is projection constrained
SELECT TOP 100 * FROM HRZN_DB.HRZN_SCH.CUSTOMER;

-- This works - exclude ZIP column
SELECT TOP 100 * EXCLUDE ZIP FROM HRZN_DB.HRZN_SCH.CUSTOMER;

-- ZIP can still be used in WHERE clause
SELECT 
    * EXCLUDE ZIP
FROM HRZN_DB.HRZN_SCH.CUSTOMER
WHERE ZIP NOT IN ('97135', '95357')
LIMIT 10;

/*************************************************/
/* D A T A      G O V E R N O R      R O L E */
/*************************************************/
USE ROLE HRZN_DATA_GOVERNOR;

-- Optional cleanup for next labs
ALTER TABLE HRZN_DB.HRZN_SCH.CUSTOMER_ORDERS UNSET AGGREGATION POLICY;
ALTER TABLE HRZN_DB.HRZN_SCH.CUSTOMER MODIFY COLUMN ZIP UNSET PROJECTION POLICY;

-- Re-apply DATA_CLASSIFICATION tag to ZIP for consistency
ALTER TABLE HRZN_DB.HRZN_SCH.CUSTOMER MODIFY COLUMN ZIP SET TAG HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION = 'SENSITIVE';

/*******************************************************************************
 * LAB 2 KEY TAKEAWAYS:
 * 
 * CLASSIFICATION:
 * AI-powered classification with custom tag mapping
 * DATA_CLASSIFICATION tag with 5 levels (PII → PUBLIC)
 * Tag propagation enabled for automatic governance
 * Custom classifiers for domain-specific data
 * 
 * MASKING:
 * Single tag-based policy for multi-level protection
 * Automatic application to all tagged columns
 * Role-based access control
 * 
 * ADVANCED POLICIES:
 * Row access policies for geographic filtering
 * Aggregation policies to prevent individual record access
 * Projection policies to control column visibility
 * 
 * PROPAGATION BENEFITS:
 * Derived tables automatically inherit tags
 * Masking policies apply without manual work
 * Scales to thousands of downstream tables
 *******************************************************************************/
