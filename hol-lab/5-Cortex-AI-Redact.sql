/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S | 
|
|Demo:         Horizon Lab - AI Governance Extensions (AI_REDACT for Unstructured Data)
|Version:      HLab v2.0
|Create Date:  Jan 26, 2026
|Author:       Severin Gassauer (severin.gassauer@snowflake.com)
|Reviewers:    TBD
|Copyright(c): 2026 Snowflake Inc. All rights reserved.
|***************************************************************************************************
|
|***************************************************************************************************
|SUMMARY OF CHANGES
|Date(yyyy-mm-dd)    Author              Comments
|------------------- ------------------- ------------------------------------------------------------
|Jan 26, 2026        Severin Gassauer    Simplified - Focus on AI_REDACT for unstructured data
|***************************************************************************************************/

/*******************************************************************************
| * SECTION 5: AI_REDACT - PII PROTECTION FOR UNSTRUCTURED DATA
| * 
| * In Lab 2, we used AI classification to protect structured columns.
| * But what about unstructured text data like customer feedback, emails, or comments?
| * 
| * This section demonstrates SNOWFLAKE.CORTEX.AI_REDACT:
| * - Purpose-built Cortex function for PII redaction in text
| * - Automatically detects and redacts 50+ PII types
| * - Works on free-form text where classification can't help
| * - Safe data for ML training, analytics, and sharing
| * 
| * What you'll learn:
| * 1. Add customer feedback with embedded PII
| * 2. Use AI_REDACT to remove PII from unstructured text
| * 3. Create redacted tables for safe ML training
| * 4. Combine AI_REDACT with Cortex functions (sentiment analysis)
| * 5. Verify classification tags propagate from Lab 2
| *******************************************************************************/

USE ROLE HRZN_DATA_GOVERNOR;
USE WAREHOUSE HRZN_WH;
USE DATABASE HRZN_DB;
USE SCHEMA HRZN_SCH;

-- ============================================================================
-- 5.1: PREPARE CUSTOMER FEEDBACK DATA WITH PII
-- ============================================================================

-- Add a feedback column to customer orders
ALTER TABLE HRZN_DB.HRZN_SCH.CUSTOMER_ORDERS 
ADD COLUMN IF NOT EXISTS CUSTOMER_FEEDBACK VARCHAR;

-- Populate with sample feedback containing various PII types
UPDATE HRZN_DB.HRZN_SCH.CUSTOMER_ORDERS
SET CUSTOMER_FEEDBACK = 
    CASE 
        WHEN MOD(ORDER_ID::INT, 10) = 0 THEN 
            'Customer John Smith called from 555-123-4567 about order. Email: john.smith@email.com. Very satisfied!'
        WHEN MOD(ORDER_ID::INT, 10) = 1 THEN 
            'Jane Doe (jane.doe@company.com) requested refund. Phone: (555) 987-6543. Issue resolved.'
        WHEN MOD(ORDER_ID::INT, 10) = 2 THEN 
            'Great product! Contact me at michael.johnson@gmail.com or 555-222-3333 for wholesale orders.'
        WHEN MOD(ORDER_ID::INT, 10) = 3 THEN 
            'Customer Sarah Williams mentioned her SSN 123-45-6789 was visible on invoice. URGENT: Fix privacy issue!'
        WHEN MOD(ORDER_ID::INT, 10) = 4 THEN 
            'Bob Martinez at 456 Oak Street, Boston MA 02101 wants expedited shipping. Call 555-444-5555.'
        WHEN MOD(ORDER_ID::INT, 10) = 5 THEN 
            'Lisa Chen from Acme Corp called about bulk pricing. Reach her at 555-777-8888 or lisa.chen@acmecorp.com.'
        WHEN MOD(ORDER_ID::INT, 10) = 6 THEN 
            'David Brown (david.b@email.net) reported shipping to wrong address: 789 Pine Ave, Seattle WA 98101.'
        WHEN MOD(ORDER_ID::INT, 10) = 7 THEN 
            'Follow up with Maria Garcia at 555-333-2222. She wants to change credit card ending in 4567.'
        WHEN MOD(ORDER_ID::INT, 10) = 8 THEN 
            'Customer feedback from james.wilson@company.org: Product exceeded expectations! My DOB is 03/15/1985 for loyalty program.'
        WHEN MOD(ORDER_ID::INT, 10) = 9 THEN 
            'Emily Davis called from 555-666-9999. Lives at 321 Elm Street, Chicago IL 60601. Wants expedited shipping.'
        ELSE 
            'Standard order processed. No issues reported.'
    END
WHERE CUSTOMER_FEEDBACK IS NULL;

-- Preview sample feedback with PII
SELECT 
    ORDER_ID,
    CUSTOMER_FEEDBACK
FROM HRZN_DB.HRZN_SCH.CUSTOMER_ORDERS 
WHERE CUSTOMER_FEEDBACK NOT LIKE 'Standard order%'
LIMIT 10;

/*******************************************************************************
 * KEY OBSERVATION: Unstructured PII Challenge
 * 
 * Customer feedback contains:
 * - Names: John Smith, Jane Doe, Sarah Williams
 * - Emails: john.smith@email.com, jane.doe@company.com
 * - Phone numbers: 555-123-4567, (555) 987-6543
 * - SSN: 123-45-6789
 * - Addresses: 456 Oak Street, Boston MA 02101
 * 
 * This is free-form text! We can use AI_REDACT to protect this unstructured PII.
 *******************************************************************************/

-- ============================================================================
-- 5.2: AI_REDACT - AUTOMATED PII REMOVAL
-- ============================================================================

-- Demo: AI_REDACT automatically detects and removes PII from text
-- Select 5 feedback samples and apply AI_REDACT
WITH sample_feedback AS (
    SELECT 
        ORDER_ID,
        CUSTOMER_FEEDBACK as original_feedback
    FROM HRZN_DB.HRZN_SCH.CUSTOMER_ORDERS 
    WHERE CUSTOMER_FEEDBACK NOT LIKE 'Standard order%'
    LIMIT 5
)
SELECT 
    ORDER_ID,
    original_feedback,
    SNOWFLAKE.CORTEX.AI_REDACT(original_feedback) as redacted_feedback
FROM sample_feedback;

/*******************************************************************************
 * KEY OBSERVATION: AI_REDACT Results
 * 
 * Compare original vs redacted feedback:
 * 
 * ORIGINAL: "Customer John Smith called from 555-123-4567..."
 * REDACTED: "Customer [NAME] called from [PHONE_NUMBER]..."
 * 
 * AI_REDACT automatically detected and replaced:
 * - Personal names → [NAME]
 * - Email addresses → [EMAIL]
 * - Phone numbers → [PHONE_NUMBER]
 * - SSN → [US_SOCIAL_SECURITY_NUMBER]
 * - Street addresses → [STREET_ADDRESS]
 * 
 * No manual regex patterns needed!
 *******************************************************************************/

-- ============================================================================
-- 5.3: CREATE REDACTED TABLE FOR SAFE ANALYTICS
-- ============================================================================
USE ROLE SYSADMIN;
-- Create redacted feedback table for ML training and analytics
-- Limited to 100 rows for demo performance
CREATE OR REPLACE TABLE HRZN_DB.HRZN_SCH.CUSTOMER_FEEDBACK_REDACTED AS
SELECT 
    ORDER_ID,
    CUSTOMER_ID,
    ORDER_TS,
    CUSTOMER_FEEDBACK as original_feedback,
    SNOWFLAKE.CORTEX.AI_REDACT(CUSTOMER_FEEDBACK) as redacted_feedback,
    CURRENT_TIMESTAMP() as redacted_at,
    CURRENT_USER() as redacted_by
FROM HRZN_DB.HRZN_SCH.CUSTOMER_ORDERS 
WHERE CUSTOMER_FEEDBACK IS NOT NULL
LIMIT 100;

-- Preview redacted table
SELECT 
    ORDER_ID,
    original_feedback,
    redacted_feedback
FROM HRZN_DB.HRZN_SCH.CUSTOMER_FEEDBACK_REDACTED
WHERE original_feedback NOT LIKE 'Standard order%'
LIMIT 10;

-- ============================================================================
-- 5.4: VERIFY TAG PROPAGATION FROM LAB 2
-- ============================================================================

-- Check if classification tags from CUSTOMER_ORDERS propagated to the new table
SELECT 
    OBJECT_NAME as TABLE_NAME,
    COLUMN_NAME,
    TAG_VALUE as CLASSIFICATION_LEVEL
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE OBJECT_DATABASE = 'HRZN_DB'
    AND OBJECT_SCHEMA = 'HRZN_SCH'
    AND OBJECT_NAME = 'CUSTOMER_FEEDBACK_REDACTED'
    AND TAG_NAME = 'DATA_CLASSIFICATION'
ORDER BY COLUMN_NAME;

/*******************************************************************************
 * KEY OBSERVATION: Automatic Tag Propagation
 * 
 * The DATA_CLASSIFICATION tags from Lab 2 automatically propagated!
 * - ORDER_ID: PUBLIC
 * - CUSTOMER_ID: (classification from CUSTOMER_ORDERS)
 * - ORDER_TS: (classification from CUSTOMER_ORDERS)
 * 
 * This means:
 * - Structured columns: Protected by classification tags + masking policies
 * - Unstructured columns: Protected by AI_REDACT
 * - Complete governance coverage with no manual work!
 *******************************************************************************/

-- ============================================================================
-- 5.5: SAFE SENTIMENT ANALYSIS WITH REDACTED DATA
-- ============================================================================

-- Use redacted data for sentiment analysis (safe for ML training)
SELECT 
    ORDER_ID,
    redacted_feedback,
    SNOWFLAKE.CORTEX.SENTIMENT(redacted_feedback) as sentiment_score,
    CASE 
        WHEN SNOWFLAKE.CORTEX.SENTIMENT(redacted_feedback) > 0.5 THEN 'Positive'
        WHEN SNOWFLAKE.CORTEX.SENTIMENT(redacted_feedback) < -0.5 THEN 'Negative'
        ELSE 'Neutral'
    END as sentiment_category
FROM HRZN_DB.HRZN_SCH.CUSTOMER_FEEDBACK_REDACTED
WHERE redacted_feedback NOT LIKE 'Standard order%'
ORDER BY sentiment_score DESC
LIMIT 10;

/*******************************************************************************
 * KEY OBSERVATION: Safe ML Training
 * 
 * Sentiment analysis works perfectly on redacted text because:
 * - Sentiment is based on context and word choice, not PII
 * - "Customer [NAME] called..." still conveys positive/negative tone
 * - We can train ML models without exposing real customer data
 * 
 * Use cases for redacted data:
 * - Sentiment analysis
 * - Topic modeling
 * - LLM fine-tuning
 * - Sharing data with third-party vendors
 * - Testing and development environments
 *******************************************************************************/

-- ============================================================================
-- 5.6: ADVANCED - PARTIAL REDACTION WITH CUSTOM ENTITY TYPES
-- ============================================================================

-- AI_REDACT can also redact specific entity types only
-- Example: Redact only names and emails, keep phone numbers

WITH feedback_sample AS (
    SELECT 
        'Contact John Smith at john.smith@email.com or call 555-123-4567 for updates.' as text
)
SELECT 
    text as original,
    SNOWFLAKE.CORTEX.AI_REDACT(text) as full_redaction,
    SNOWFLAKE.CORTEX.AI_REDACT(text, ['NAME', 'EMAIL']) as partial_redaction
FROM feedback_sample;

/*******************************************************************************
 * KEY OBSERVATION: Selective Redaction
 * 
 * FULL REDACTION: "[NAME] at [EMAIL] or call [PHONE_NUMBER]..."
 * PARTIAL REDACTION: "[NAME] at [EMAIL] or call 555-123-4567..."
 * 
 * You can specify exactly which PII types to redact based on your use case!
 *******************************************************************************/

-- ============================================================================
-- 5.7: COMBINE WITH ROLE-BASED ACCESS
-- ============================================================================

-- Governors see original feedback, analysts see redacted version
-- Create a secure view using pre-redacted table
USE ROLE HRZN_DATA_GOVERNOR;
CREATE OR REPLACE SECURE VIEW HRZN_DB.HRZN_SCH.CUSTOMER_FEEDBACK_SECURE AS
SELECT 
    ORDER_ID,
    CUSTOMER_ID,
    ORDER_TS,
    CASE 
        WHEN CURRENT_ROLE() IN ('HRZN_DATA_GOVERNOR', 'ACCOUNTADMIN') 
        THEN original_feedback
        ELSE redacted_feedback
    END as CUSTOMER_FEEDBACK,
    redacted_at,
    redacted_by
FROM HRZN_DB.HRZN_SCH.CUSTOMER_FEEDBACK_REDACTED;

-- Test as governor (sees original PII)
USE ROLE HRZN_DATA_GOVERNOR;
SELECT 
    ORDER_ID,
    CUSTOMER_FEEDBACK
FROM HRZN_DB.HRZN_SCH.CUSTOMER_FEEDBACK_SECURE 
WHERE CUSTOMER_FEEDBACK NOT LIKE 'Standard order%' 
LIMIT 5;

-- Test as data user (sees redacted version)
USE ROLE HRZN_DATA_USER;
SELECT 
    ORDER_ID,
    CUSTOMER_FEEDBACK
FROM HRZN_DB.HRZN_SCH.CUSTOMER_FEEDBACK_SECURE 
WHERE CUSTOMER_FEEDBACK NOT LIKE 'Standard order%' 
LIMIT 5;

USE ROLE HRZN_DATA_GOVERNOR;

/*******************************************************************************
 * KEY OBSERVATION: Efficient Dynamic Redaction by Role
 * 
 * Same view, different results based on role:
 * - HRZN_DATA_GOVERNOR: Sees original PII (for governance/compliance)
 * - HRZN_DATA_USER: Sees pre-computed redacted version (for analytics/ML)
 * 
 * Performance benefits:
 * - AI_REDACT runs once during table creation (not on every query)
 * - View just selects pre-computed columns (instant results)
 * - Limited to 100 rows for demo performance
 * 
 * This combines Snowflake RBAC with AI-powered redaction efficiently!
 *******************************************************************************/

-- ============================================================================
-- 5.8: BUSINESS INSIGHTS FROM REDACTED DATA
-- ============================================================================

-- Analyze feedback themes without exposing PII
WITH feedback_analysis AS (
    SELECT 
        ORDER_ID,
        redacted_feedback,
        SNOWFLAKE.CORTEX.SENTIMENT(redacted_feedback) as sentiment,
        CASE 
            WHEN LOWER(redacted_feedback) LIKE '%refund%' THEN 'Refund Request'
            WHEN LOWER(redacted_feedback) LIKE '%shipping%' OR LOWER(redacted_feedback) LIKE '%expedited%' THEN 'Shipping Issue'
            WHEN LOWER(redacted_feedback) LIKE '%bulk%' OR LOWER(redacted_feedback) LIKE '%wholesale%' THEN 'Bulk Order'
            WHEN LOWER(redacted_feedback) LIKE '%credit card%' THEN 'Payment Issue'
            WHEN LOWER(redacted_feedback) LIKE '%urgent%' OR LOWER(redacted_feedback) LIKE '%privacy%' THEN 'Urgent Issue'
            ELSE 'General Feedback'
        END as feedback_category
    FROM HRZN_DB.HRZN_SCH.CUSTOMER_FEEDBACK_REDACTED
    WHERE redacted_feedback NOT LIKE 'Standard order%'
)
SELECT 
    feedback_category,
    COUNT(*) as feedback_count,
    AVG(sentiment) as avg_sentiment,
    CASE 
        WHEN AVG(sentiment) > 0.3 THEN 'Positive'
        WHEN AVG(sentiment) < -0.3 THEN 'Negative'
        ELSE 'Neutral'
    END as sentiment_label
FROM feedback_analysis
GROUP BY feedback_category
ORDER BY feedback_count DESC;

/*******************************************************************************
 * KEY OBSERVATION: Business Value Without PII Exposure
 * 
 * We can derive business insights from customer feedback:
 * - Which categories have most feedback?
 * - What's the sentiment by category?
 * - Where should support focus attention?
 * 
 * All without exposing a single piece of PII!
 *******************************************************************************/

/*******************************************************************************
 * KEY TAKEAWAYS - LAB 5:
 * 
 * AI_REDACT USE CASES:
 * - Customer feedback and reviews
 * - Support tickets and chat logs
 * - Email content analysis
 * - Social media mentions
 * - Survey responses with open-ended questions
 * - Legal documents and contracts
 * 
 * INTEGRATION WITH LAB 2 CLASSIFICATION:
 * - Structured columns: Protected by classification tags (Lab 2)
 * - Unstructured text: Protected by AI_REDACT (Lab 5)
 * - Tags propagate automatically to derived tables
 * - Complete governance coverage
 * 
 * BENEFITS FOR DATA GOVERNORS:
 * - No regex patterns to write/maintain
 * - Detects 50+ PII types automatically
 * - Works in any language (multilingual support)
 * - Safe data sharing with vendors/partners
 * - Compliant ML training data
 * - Combines with RBAC for fine-grained control
 * 
 *******************************************************************************/
