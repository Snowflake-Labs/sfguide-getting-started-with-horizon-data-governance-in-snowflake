
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
    HRZN_DB.HRZN_SCH.HRZN_CLASSIFICATION_PROFILE(
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
    SET CLASSIFICATION_PROFILE = 'HRZN_DB.HRZN_SCH.HRZN_CLASSIFICATION_PROFILE';

-- Run AI classification on CUSTOMER table
CALL SYSTEM$CLASSIFY(
    'HRZN_DB.HRZN_SCH.CUSTOMER',
    'HRZN_DB.HRZN_SCH.HRZN_CLASSIFICATION_PROFILE'
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
-- 5. CREATE TAG-BASED MASKING POLICY
/****************************************************/
USE ROLE HRZN_DATA_GOVERNOR;
USE SCHEMA HRZN_DB.TAG_SCHEMA;

-- Create a single masking policy for all classification levels
CREATE MASKING POLICY HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION_MASKING_POLICY 
AS (VAL STRING) 
RETURNS STRING ->
CASE
    -- PII: Full redaction for non-governors
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'PII'
         AND CURRENT_ROLE() NOT IN ('HRZN_DATA_GOVERNOR', 'ACCOUNTADMIN')
    THEN '***PII-REDACTED***'
    
    -- RESTRICTED: Partial masking for DATA_USER
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'RESTRICTED'
         AND CURRENT_ROLE() IN ('HRZN_DATA_USER')
    THEN CONCAT('***-', RIGHT(VAL, 4))
    
    -- SENSITIVE: Hash for DATA_USER
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION') = 'SENSITIVE'
         AND CURRENT_ROLE() IN ('HRZN_DATA_USER')
    THEN SHA2(VAL, 256)
    
    -- INTERNAL and PUBLIC: Visible to all (no masking)
    ELSE VAL
END;

-- Attach masking policy to the DATA_CLASSIFICATION tag
ALTER TAG HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION 
    SET MASKING POLICY HRZN_DB.TAG_SCHEMA.DATA_CLASSIFICATION_MASKING_POLICY;

/*******************************************************************************
 * KEY BENEFIT: Single Policy, Multi-Level Protection
 * 
 * One masking policy handles all classification levels:
 * - PII: Fully redacted (***PII-REDACTED***)
 * - RESTRICTED: Partially masked (***-1234)
 * - SENSITIVE: SHA2 hash
 * - INTERNAL/PUBLIC: Visible
 * 
 * Policy applies automatically to ANY column tagged with DATA_CLASSIFICATION!
 *******************************************************************************/

/****************************************************/
-- 6. TEST MASKING WITH DIFFERENT ROLES
/****************************************************/

-- As HRZN_DATA_GOVERNOR: Full visibility
USE ROLE HRZN_DATA_GOVERNOR;
SELECT 
    ID,              -- PUBLIC
    FIRST_NAME,      -- SENSITIVE
    EMAIL,           -- PII
    SSN,             -- PII
    PHONE_NUMBER,    -- RESTRICTED
    BIRTHDATE,       -- RESTRICTED
    COMPANY          -- INTERNAL
FROM HRZN_DB.HRZN_SCH.CUSTOMER
LIMIT 5;

-- As HRZN_DATA_USER: Multi-level masking
USE ROLE HRZN_DATA_USER;
SELECT 
    ID,              -- PUBLIC: Visible
    FIRST_NAME,      -- SENSITIVE: Hashed
    EMAIL,           -- PII: Fully redacted
    SSN,             -- PII: Fully redacted
    PHONE_NUMBER,    -- RESTRICTED: Partial mask (***-1234)
    BIRTHDATE,       -- RESTRICTED: Partial mask (***-0590)
    COMPANY          -- INTERNAL: Visible
FROM HRZN_DB.HRZN_SCH.CUSTOMER
LIMIT 5;

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
-- 8. ROW ACCESS POLICIES
/****************************************************/

/*----------------------------------------------------------------------------------
Step- Row-Access Policies

A row access policy is a schema-level object that determines whether a given row 
in a table or view can be viewed from SELECT, UPDATE, DELETE, and MERGE statements.

Within our Customer table, the users with HRZN_DATA_USER should only see Customers 
who are based in Massachusetts (MA).
----------------------------------------------------------------------------------*/

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
