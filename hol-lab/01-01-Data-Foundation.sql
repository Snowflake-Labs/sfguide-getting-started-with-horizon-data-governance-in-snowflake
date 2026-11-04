/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale
Part:         PART 1 - Data Governance
Section:      01-01 - Data Foundation (the governed base the whole arc rests on)
Persona:      AGOV_PIPELINE_SERVICE_ROLE (owns and builds RAW -> BRONZE); AGOV_ENGINEER (reads BRONZE afterward)
Story beat:   Before you can govern AI, you need governed DATA. RAW -> BRONZE only ever runs under
              the non-interactive service role - never AGOV_ENGINEER. In this lab we do that with a
              literal USE ROLE AGOV_PIPELINE_SERVICE_ROLE; in a real deployment, this step would run
              unattended via a Task, DCM project, or dbt run under the service account's credentials,
              never a human interactively switching roles. AGOV_ENGINEER never gets RAW access and
              never owns BRONZE, but reads BRONZE afterward (masked) to learn the shape of the data.
              RAW stays ungoverned as a contrast; BRONZE will be classified/masked in 01-02; SILVER
              analytics will inherit that governance via tag propagation.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
****************************************************************************************************/

-- ============================================================================
-- 1.1  RAW -> BRONZE  (built directly by AGOV_PIPELINE_SERVICE_ROLE)
--      No stored procedure indirection - the service role's own identity is the
--      control point, not an owner's-rights wrapper. AGOV_ENGINEER never runs
--      this block and never holds SELECT on RAW or OWNERSHIP on BRONZE.
-- ============================================================================
USE ROLE AGOV_PIPELINE_SERVICE_ROLE;
USE WAREHOUSE AGOV_WH;
USE DATABASE AGENTIC_GOV_DB;

-- OPTIN is the per-customer consent flag. In 01-02, it becomes the row access policy
-- argument on the contact activation view (CUSTOMER_CONTACT_ACTIVATION_V) for the
-- CONTACT_ACTIVATION purpose. The analytics DT (CUSTOMER_ORDER_ANALYTICS) has NO row
-- access policy and includes all customers; consent is scoped to the activation surface.
-- Store OPTIN as BOOLEAN so the STRING/DATE tag-based masking policies never attach to
-- it. Derived deterministically from HASH(ID) rather than trusting RAW's OPTIN string: stable
-- across reloads, independent of source-file skew, gives an even Y/N mix.
CREATE OR REPLACE TABLE AGENTIC_GOV_DB.BRONZE.CUSTOMER AS
    SELECT * REPLACE (
        (BITAND(HASH(ID), 1) = 0) AS OPTIN,
        TO_DATE(BIRTHDATE, 'YYYY-MM-DD') AS BIRTHDATE
    ) FROM AGENTIC_GOV_DB.RAW.CUSTOMER_RAW;

CREATE OR REPLACE TABLE AGENTIC_GOV_DB.BRONZE.CUSTOMER_ORDERS AS
    SELECT * FROM AGENTIC_GOV_DB.RAW.CUSTOMER_ORDERS_RAW;

-- ============================================================================
-- 1.2  DATA QUALITY (Data Metric Functions on BRONZE.CUSTOMER)
--      Trustworthy AI requires trustworthy data - start by measuring it.
--      Still AGOV_PIPELINE_SERVICE_ROLE: ADD DATA METRIC FUNCTION requires
--      ownership-level privilege on the table, which only the service role holds.
-- ============================================================================
ALTER TABLE AGENTIC_GOV_DB.BRONZE.CUSTOMER SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
ALTER TABLE AGENTIC_GOV_DB.BRONZE.CUSTOMER ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT      ON (EMAIL);
ALTER TABLE AGENTIC_GOV_DB.BRONZE.CUSTOMER ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (EMAIL);
ALTER TABLE AGENTIC_GOV_DB.BRONZE.CUSTOMER ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT       ON ();

-- Custom DMF: invalid email format count. Created by the service role (it owns
-- BRONZE.CUSTOMER, and ATTACHING a DMF needs ownership-level privilege on the
-- table). AGOV_ENGINEER gets USAGE so it can still call the function directly
-- to inspect data quality without needing table ownership (section 1.3).
CREATE OR REPLACE DATA METRIC FUNCTION AGENTIC_GOV_DB.GOVERNANCE.INVALID_EMAIL_COUNT(IN_TABLE TABLE(IN_COL STRING))
RETURNS NUMBER
AS
$$ SELECT COUNT_IF(FALSE = (IN_COL REGEXP '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}$')) FROM IN_TABLE $$;

ALTER TABLE AGENTIC_GOV_DB.BRONZE.CUSTOMER
    ADD DATA METRIC FUNCTION AGENTIC_GOV_DB.GOVERNANCE.INVALID_EMAIL_COUNT ON (EMAIL);

GRANT USAGE ON FUNCTION AGENTIC_GOV_DB.GOVERNANCE.INVALID_EMAIL_COUNT(TABLE(STRING)) TO ROLE AGOV_ENGINEER;

-- ============================================================================
-- 1.3  ENGINEER READS THE SHAPE OF THE DATA
--      Right now nothing is classified yet, so these DMF calls and the pipeline
--      SQL AGOV_ENGINEER writes/tests operate on the real shape (row counts, joins,
--      NULL rates) without ever holding RAW access or BRONZE ownership.
-- ============================================================================
USE ROLE AGOV_ENGINEER;
USE WAREHOUSE AGOV_WH;
USE DATABASE AGENTIC_GOV_DB;

SELECT SNOWFLAKE.CORE.NULL_COUNT      (SELECT EMAIL FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER) AS null_emails;
SELECT SNOWFLAKE.CORE.DUPLICATE_COUNT (SELECT EMAIL FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER) AS duplicate_emails;
SELECT AGENTIC_GOV_DB.GOVERNANCE.INVALID_EMAIL_COUNT(SELECT EMAIL FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER) AS invalid_emails;

-- ============================================================================
-- 1.4  VALIDATION
-- ============================================================================
SELECT 'BRONZE.CUSTOMER'        AS obj, COUNT(*) AS row_count FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER
UNION ALL
SELECT 'BRONZE.CUSTOMER_ORDERS' AS obj, COUNT(*) FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER_ORDERS;
-- Expected: 1000 | 30000

-- Fixture checks (every PASSED = TRUE). Run as the pipeline identity that built BRONZE.
USE ROLE AGOV_PIPELINE_SERVICE_ROLE;
USE SECONDARY ROLES NONE;

SELECT 'unique_customer_keys' AS check_name,
       COUNT(*) = 1000 AND COUNT(DISTINCT ID) = 1000
       AND MIN(ID) = 1 AND MAX(ID) = 1000 AS passed
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER;

SELECT 'unique_order_keys' AS check_name,
       COUNT(*) = 30000 AND COUNT(DISTINCT ORDER_ID) = 30000
       AND MIN(TO_NUMBER(ORDER_ID)) = 1 AND MAX(TO_NUMBER(ORDER_ID)) = 30000
       AND MIN(TO_NUMBER(CUSTOMER_ID)) = 1 AND MAX(TO_NUMBER(CUSTOMER_ID)) = 900 AS passed
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER_ORDERS;

-- Every order belongs to a known customer (100 customers have no orders).
SELECT 'order_relationship' AS check_name, COUNT(*) = 0 AS passed
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER_ORDERS orders
LEFT JOIN AGENTIC_GOV_DB.BRONZE.CUSTOMER customer ON customer.ID = TRY_TO_NUMBER(orders.CUSTOMER_ID)
WHERE customer.ID IS NULL;

SELECT 'valid_birthdates' AS check_name, COUNT_IF(BIRTHDATE IS NULL) = 0 AS passed
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER;
