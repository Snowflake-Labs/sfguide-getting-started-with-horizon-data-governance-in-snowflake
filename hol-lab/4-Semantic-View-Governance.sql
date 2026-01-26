/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S | 

Demo:         Horizon Lab - AI Governance Extensions (Semantic View Governance)
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
Jan 26, 2026        Severin Gassauer    Initial AI Governance Extension - Semantic Views
***************************************************************************************************/

/*******************************************************************************
 * SECTION 4: SEMANTIC VIEW GOVERNANCE
 * 
 * This section demonstrates how to govern AI assets using SEMANTIC VIEWS
 * for Cortex Analyst, ensuring data governance policies flow through to AI queries.
 * 
 * What you'll learn:
 * - Create semantic views (database objects) over governed data
 * - Apply tags to semantic views
 * - Demonstrate policy inheritance in Analyst queries
 * - Track semantic view lineage
 * - Query semantic views with SEMANTIC_VIEW() function
 * 
 * NOTE: Semantic Views are DATABASE OBJECTS created with SQL, NOT YAML files.
 *       This is the current/recommended approach for Cortex Analyst.
 *******************************************************************************/

-- ============================================================================
-- 4.0: SETUP - SET CONTEXT
-- ============================================================================
-- NOTE: Required privileges are granted in 0-lab-Setup.sql
-- If you get permission errors, verify that setup was run successfully

-- Switch to the governance role
USE ROLE HRZN_DATA_GOVERNOR;
USE WAREHOUSE HRZN_WH;
USE DATABASE HRZN_DB;
USE SCHEMA HRZN_SCH;

-- ============================================================================
-- 4.1: CREATE SEMANTIC VIEW FOR CORTEX ANALYST
-- ============================================================================
-- Semantic Views are first-class database objects that define:
-- - Logical tables (mapped to physical tables)
-- - Relationships between tables
-- - Facts (raw values for calculations)
-- - Dimensions (attributes for grouping/filtering)
-- - Metrics (aggregated measures)
-- ============================================================================
USE ROLE HRZN_DATA_GOVERNOR;

CREATE OR REPLACE SEMANTIC VIEW CUSTOMER_ORDER_ANALYTICS

  TABLES (
    customers AS HRZN_DB.HRZN_SCH.CUSTOMER
      PRIMARY KEY (ID)
      WITH SYNONYMS ('customer', 'clients', 'buyers')
      COMMENT = 'Customer master data with PII protection',
      
    orders AS HRZN_DB.HRZN_SCH.CUSTOMER_ORDERS
      PRIMARY KEY (ORDER_ID)
      WITH SYNONYMS ('sales orders', 'transactions', 'purchases')
      COMMENT = 'Customer order transactions'
  )

  RELATIONSHIPS (
    orders_to_customers AS
      orders (CUSTOMER_ID) REFERENCES customers (ID)
  )

  FACTS (
    orders.order_amount_fact AS ORDER_AMOUNT
      COMMENT = 'Order amount before tax',
    orders.order_tax_fact AS ORDER_TAX
      COMMENT = 'Tax amount on order',
    orders.order_total_fact AS ORDER_TOTAL
      COMMENT = 'Total order amount including tax'
  )

  DIMENSIONS (
    -- Customer dimensions
    customers.customer_name AS CONCAT(FIRST_NAME, ' ', LAST_NAME)
      WITH SYNONYMS = ('full name', 'name')
      COMMENT = 'Customer full name',
    customers.first_name AS FIRST_NAME
      COMMENT = 'Customer first name',
    customers.last_name AS LAST_NAME
      COMMENT = 'Customer last name',
    customers.email_address AS EMAIL
      WITH SYNONYMS = ('email', 'contact email')
      COMMENT = 'Customer email (masked for non-admin roles)',
    customers.phone AS PHONE_NUMBER
      WITH SYNONYMS = ('phone number', 'contact number')
      COMMENT = 'Customer phone (conditionally masked)',
    customers.location_state AS STATE
      WITH SYNONYMS = ('state', 'region')
      COMMENT = 'Customer state (subject to row-level security)',
    customers.location_city AS CITY
      WITH SYNONYMS = ('city', 'town')
      COMMENT = 'Customer city',
    customers.company_name AS COMPANY
      WITH SYNONYMS = ('company', 'employer', 'organization')
      COMMENT = 'Customer company',
    customers.job_title AS JOB
      WITH SYNONYMS = ('job', 'position', 'role')
      COMMENT = 'Customer job title',
    customers.customer_id AS ID
      COMMENT = 'Unique customer identifier',
      
    -- Order dimensions  
    orders.order_id AS ORDER_ID
      WITH SYNONYMS = ('order number')
      COMMENT = 'Unique order identifier',
    orders.order_date AS ORDER_TS
      WITH SYNONYMS = ('date', 'order timestamp')
      COMMENT = 'Order date',
    orders.order_year AS YEAR(ORDER_TS)
      COMMENT = 'Year when the order was placed',
    orders.order_month AS MONTH(ORDER_TS)
      COMMENT = 'Month when the order was placed',
    orders.currency AS ORDER_CURRENCY
      WITH SYNONYMS = ('order currency')
      COMMENT = 'Order currency code'
  )

  METRICS (
    customers.customer_count AS COUNT(ID)
      COMMENT = 'Count of customers',
    orders.total_revenue AS SUM(orders.order_total_fact)
      WITH SYNONYMS = ('total sales', 'revenue')
      COMMENT = 'Total revenue from orders',
    orders.total_orders AS COUNT(ORDER_ID)
      WITH SYNONYMS = ('order count', 'number of orders')
      COMMENT = 'Total number of orders',
    orders.average_order_value AS AVG(orders.order_total_fact)
      WITH SYNONYMS = ('AOV', 'avg order')
      COMMENT = 'Average order value',
    orders.total_tax AS SUM(orders.order_tax_fact)
      COMMENT = 'Total tax collected',
    orders.max_order AS MAX(orders.order_total_fact)
      COMMENT = 'Largest single order',
    orders.min_order AS MIN(orders.order_total_fact)
      COMMENT = 'Smallest single order'
  )

  COMMENT = 'Semantic view for customer order analysis with built-in governance';

-- ============================================================================
-- 4.2: VERIFY THE SEMANTIC VIEW
-- ============================================================================

-- List semantic views
SHOW SEMANTIC VIEWS LIKE 'CUSTOMER_ORDER_ANALYTICS';

-- Show all dimensions
SHOW SEMANTIC DIMENSIONS IN CUSTOMER_ORDER_ANALYTICS;

-- Show all metrics  
SHOW SEMANTIC METRICS IN CUSTOMER_ORDER_ANALYTICS;

-- Show all facts
SHOW SEMANTIC FACTS IN CUSTOMER_ORDER_ANALYTICS;

-- Describe the semantic view
DESCRIBE SEMANTIC VIEW CUSTOMER_ORDER_ANALYTICS;

-- ============================================================================
-- 4.3: QUERY THE SEMANTIC VIEW
-- ============================================================================

-- Use the SEMANTIC_VIEW() function to query
-- This generates SQL based on the semantic model definitions

-- Total revenue by state
SELECT * FROM SEMANTIC_VIEW(
    CUSTOMER_ORDER_ANALYTICS
    DIMENSIONS customers.location_state
    METRICS orders.total_revenue, orders.total_orders
)
ORDER BY TOTAL_REVENUE DESC;

-- Top 10 customers by revenue
SELECT * FROM SEMANTIC_VIEW(
    CUSTOMER_ORDER_ANALYTICS
    DIMENSIONS customers.customer_name, customers.company_name
    METRICS orders.total_revenue, orders.total_orders
)
ORDER BY TOTAL_REVENUE DESC
LIMIT 10;

-- Monthly revenue trend
SELECT * FROM SEMANTIC_VIEW(
    CUSTOMER_ORDER_ANALYTICS
    DIMENSIONS orders.order_year, orders.order_month
    METRICS orders.total_revenue, orders.average_order_value
)
ORDER BY ORDER_YEAR, ORDER_MONTH;

-- Revenue by currency
SELECT * FROM SEMANTIC_VIEW(
    CUSTOMER_ORDER_ANALYTICS
    DIMENSIONS orders.currency
    METRICS orders.total_revenue, orders.total_orders, orders.average_order_value
);

-- ============================================================================
-- 4.4: VERIFY POLICY INHERITANCE
-- ============================================================================
-- This is the KEY governance feature - existing masking and row access
-- policies on the underlying tables automatically apply to semantic view queries!

-- As HRZN_DATA_GOVERNOR - see all data (no masking, all rows)
SELECT * FROM SEMANTIC_VIEW(
    CUSTOMER_ORDER_ANALYTICS
    DIMENSIONS customers.customer_name, customers.email_address, customers.location_state
    METRICS orders.total_revenue
)
LIMIT 5;

-- Now test as HRZN_DATA_USER (restricted role)
USE ROLE HRZN_DATA_USER;

-- Email should be MASKED
-- Only MA state should be visible (row access policy)
SELECT * FROM SEMANTIC_VIEW(
    CUSTOMER_ORDER_ANALYTICS
    DIMENSIONS customers.customer_name, customers.email_address, customers.location_state
    METRICS orders.total_revenue
)
LIMIT 5;

-- Notice:
-- 1. EMAIL column shows masked values (e.g., ***MASKED***)
-- 2. Only Massachusetts (MA) state records are visible
-- 3. This happens automatically - no special AI policy needed!

-- Switch back to governor role
USE ROLE HRZN_DATA_GOVERNOR;

-- ============================================================================
-- 4.5: USE WITH CORTEX ANALYST (SNOWFLAKE INTELLIGENCE)
-- ============================================================================
/*
To use this semantic view with Cortex Analyst in Snowsight:

1. Open Snowsight (https://<your-account>.snowflakecomputing.com)
2. Click "Projects" → "Cortex Analyst" in left navigation
   OR use the "Ask Snowflake" / "Snowflake Intelligence" feature
3. Select semantic view: HRZN_DB.HRZN_SCH.CUSTOMER_ORDER_ANALYTICS
4. Ask natural language questions:
   - "What are the total sales by state?"
   - "Who are my top 10 customers by revenue?"
   - "What is the average order value?"
   - "Show me monthly revenue trends"
   - "Which companies have the most orders?"
   - "What is total revenue for California?"

KEY GOVERNANCE BENEFIT:
- If you're logged in as HRZN_DATA_USER, the AI will return MASKED emails
- Row access policies will filter the data automatically
- No additional configuration needed - governance just works!


-- ============================================================================
-- 4.6: DEMO SCRIPT - TESTING FINE-GRAINED ACCESS CONTROL IN CORTEX ANALYST UI
-- ============================================================================
/*
IMPORTANT DEMO: This demonstrates that data governance policies automatically
flow through to AI-generated queries without any additional configuration.

STEP 1: TEST AS DATA GOVERNOR (Full Access)
--------------------------------------------
1. In Snowsight, switch role to HRZN_DATA_GOVERNOR:
   - Click your profile (top right)
   - Select "Switch Role"
   - Choose HRZN_DATA_GOVERNOR

2. Open Cortex Analyst:
   - Go to "Projects" → "Cortex Analyst"
   - Select semantic view: HRZN_DB.HRZN_SCH.CUSTOMER_ORDER_ANALYTICS

3. Ask: "Show me total revenue by state"
   EXPECTED RESULT:
   - You should see ALL states (MA, CA, NY, TX, FL, etc.)
   - Revenue numbers for every state

4. Ask: "Get me the full names and phone number of our ten highest billing customers per state"
   EXPECTED RESULT:
   - You should see customers from ALL states
   - Phone numbers will be VISIBLE for customers with OPTIN='Y'
   - Phone numbers will be ***MASKED*** for customers with OPTIN='N'
   - This demonstrates CONDITIONAL masking based on OPTIN column
   - Top 10 customers per state shown

5. Ask: "How many customers do we have in California?"
   EXPECTED RESULT:
   - You should see California customers (and count)


STEP 2: TEST AS DATA USER (Restricted Access)
---------------------------------------------
1. In Snowsight, switch role to HRZN_DATA_USER:
   - Click your profile (top right)
   - Select "Switch Role"
   - Choose HRZN_DATA_USER

2. Stay in Cortex Analyst with same semantic view:
   - HRZN_DB.HRZN_SCH.CUSTOMER_ORDER_ANALYTICS

3. Ask: "Show me total revenue by state"
   EXPECTED RESULT:
   - You should ONLY see Massachusetts (MA) - other states filtered!
   - This is the row access policy in action
   - The AI query respects row-level security automatically

4. Ask: "Get me the full names and phone number of our ten highest billing customers per state"
   EXPECTED RESULT:
   - You should ONLY see Massachusetts (MA) customers - no CA, NY, TX, FL!
   - This demonstrates ROW ACCESS POLICY filtering by state
   - Phone numbers: Mix of visible and ***MASKED*** based on OPTIN
   - This demonstrates CONDITIONAL MASKING in action
   - Full names are visible (not sensitive data)
   - Top billing customers in MA only

5. Ask: "How many customers do we have in California?"
   EXPECTED RESULT:
   - Should return 0 or "no data" 
   - California data is filtered by row access policy


WHAT THIS DEMONSTRATES:
------------------------
- Existing masking policies (EMAIL, SSN, CREDITCARD) automatically apply to AI queries
- Row access policies (MA-only filter) automatically apply to AI queries
- Conditional masking (PHONE based on OPTIN) automatically applies
- Aggregation policies automatically apply
- NO SPECIAL AI CONFIGURATION NEEDED - governance flows naturally!
- Same semantic view, different results based on role - that's proper RBAC

This is the KEY VALUE PROPOSITION:
- You don't need separate "AI policies"
- You don't need to configure Cortex Analyst differently
- Your existing Horizon governance automatically protects AI/LLM queries
- Data governance is unified across SQL, Python, and AI workloads


ADDITIONAL TEST CASES (Optional):
----------------------------------
As HRZN_DATA_USER, also try:
- "Show me phone numbers for customers" → Should see some masked based on OPTIN
- "What is the average order value?" → Should work (aggregations allowed)
- "Show me SSN or credit card numbers" → Should see MASKED values
- "Which states have the highest revenue?" → Should only see MA


TROUBLESHOOTING:
----------------
If masking/filtering doesn't work:
1. Verify policies are applied to tables:
   SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES 
   WHERE REF_ENTITY_NAME IN ('CUSTOMER', 'CUSTOMER_ORDERS');

2. Verify role grants:
   SHOW GRANTS TO ROLE HRZN_DATA_USER;

3. Test direct table query first (without semantic view):
   USE ROLE HRZN_DATA_USER;
   SELECT EMAIL, STATE FROM HRZN_DB.HRZN_SCH.CUSTOMER LIMIT 10;
   -- Should see masked emails and only MA state

4. If semantic view shows different results than direct table query,
   check semantic view definition for COPY GRANTS clause
*/

-- ============================================================================
-- KEY TAKEAWAYS:
-- 
-- 1. Semantic Views are DATABASE OBJECTS created with CREATE SEMANTIC VIEW
-- 2. They define business-friendly names for tables, dimensions, metrics
-- 3. Query them with SEMANTIC_VIEW() function or Cortex Analyst UI
-- 4. ALL existing policies (masking, row access) automatically apply to AI queries
-- 5. Can be tagged for governance tracking
-- 6. Lineage is tracked in OBJECT_DEPENDENCIES
-- 7. No YAML files or stages needed - it's all SQL!
-- 8. CRITICAL: Test with different roles in Cortex Analyst UI to demonstrate
--    that governance policies automatically protect AI-generated queries
-- ============================================================================
