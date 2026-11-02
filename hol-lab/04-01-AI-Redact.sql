/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale
Part:         PART 4 - AI-Assisted Governance (use AI to help govern)
Section:      04-01 - AI_REDACT for unstructured text
Persona:      AGOV_GOVERNOR (data custodian)
Story beat:   Parts 1-3 govern the data, the agent, and how data may leave. This is the flip side:
              using AI to DO governance. Column classification cannot reach PII buried in
              free-form text. AI_REDACT detects 50+ entity types with no regex, so unstructured
              feedback becomes safe to analyze. A standalone story - it does not depend on the agent.
Before:       02-01 model grants (LLAMA3.1-70B, ARCTIC-SENTIMENT) and the 02-04.6 RSS cleanup,
              then a fresh session. Runs as a batch.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
****************************************************************************************************/

USE ROLE AGOV_GOVERNOR;
USE WAREHOUSE AGOV_WH;
USE DATABASE AGENTIC_GOV_DB;
USE SCHEMA SILVER;
USE SECONDARY ROLES NONE;

-- ============================================================================
-- 04-01.1  REDACT UNSTRUCTURED TEXT (where column classification can't reach)
-- ============================================================================
-- Synthetic free-form feedback with embedded PII: names, emails, phones, SSN, addresses,
-- date of birth, credit-card hints. This is the unstructured PII that column classification
-- (Part 1) cannot reach.
CREATE OR REPLACE TABLE AGENTIC_GOV_DB.SILVER.CUSTOMER_FEEDBACK AS
SELECT * FROM VALUES
  (1,  'Customer John Smith called from 555-123-4567 about order. Email john.smith@example.com. Very satisfied!'),
  (2,  'Jane Doe (jane.doe@example.org) requested a refund. Phone (555) 987-6543. Issue resolved.'),
  (3,  'Great product! Contact me at michael.johnson@example.net or 555-222-3333 for wholesale orders.'),
  (4,  'Sarah Williams said her SSN 123-45-6789 was visible on the invoice. URGENT: fix privacy issue!'),
  (5,  'Bob Martinez at 456 Oak Street, Boston MA 02101 wants expedited shipping. Call 555-444-5555.'),
  (6,  'Lisa Chen from Acme Corp called about bulk pricing. Reach her at 555-777-8888 or lisa.chen@acme.example.com.'),
  (7,  'David Brown (david.b@example.net) reported shipping to wrong address: 789 Pine Ave, Seattle WA 98101.'),
  (8,  'Follow up with Maria Garcia at 555-333-2222. She wants to change the credit card ending in 4567.'),
  (9,  'Feedback from james.wilson@example.org: product exceeded expectations! My DOB is 03/15/1985 for loyalty.'),
  (10, 'Emily Davis called from 555-666-9999. Lives at 321 Elm Street, Chicago IL 60601. Wants expedited shipping.'),
  (11, 'Standard order processed. No issues reported.')
AS feedback(FEEDBACK_ID, FEEDBACK_TEXT);

-- Original vs redacted, side by side. AI_REDACT detects 50+ PII types with no regex.
SELECT
    FEEDBACK_ID,
    FEEDBACK_TEXT                              AS original_feedback,
    SNOWFLAKE.CORTEX.AI_REDACT(FEEDBACK_TEXT)  AS redacted_feedback
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_FEEDBACK
WHERE FEEDBACK_TEXT NOT LIKE 'Standard order%'
ORDER BY FEEDBACK_ID;
-- Names -> [NAME], emails -> [EMAIL], phones -> [PHONE_NUMBER], SSN -> [US_SOCIAL_SECURITY_NUMBER],
-- addresses -> [STREET_ADDRESS], dates -> [DATE].

-- Pre-compute redaction once into a table (cheap: runs at load, not on every query)
CREATE OR REPLACE TABLE AGENTIC_GOV_DB.SILVER.CUSTOMER_FEEDBACK_REDACTED AS
SELECT
    FEEDBACK_ID,
    FEEDBACK_TEXT                              AS original_feedback,
    SNOWFLAKE.CORTEX.AI_REDACT(FEEDBACK_TEXT)  AS redacted_feedback,
    CURRENT_TIMESTAMP()                        AS redacted_at
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_FEEDBACK;

-- ============================================================================
-- 04-01.2  SELECTIVE REDACTION (redact only chosen entity types)
-- ============================================================================
-- Inspect residual content after full or selective redaction; neither is a universal PII guarantee.
WITH s AS (SELECT 'Contact John Smith at john.smith@example.com or call 555-123-4567 for updates.' AS txt)
SELECT
    txt                                          AS original,
    SNOWFLAKE.CORTEX.AI_REDACT(txt)              AS full_redaction,
    SNOWFLAKE.CORTEX.AI_REDACT(txt, ['NAME','EMAIL']) AS names_and_emails_only
FROM s;

-- ============================================================================
-- 04-01.3  SAFE ML / ANALYTICS ON REDACTED TEXT
-- ============================================================================
-- Sentiment depends on tone, not PII, so it works fine on redacted text.
SELECT
    FEEDBACK_ID,
    redacted_feedback,
    SNOWFLAKE.CORTEX.SENTIMENT(redacted_feedback) AS sentiment_score
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_FEEDBACK_REDACTED
WHERE redacted_feedback NOT LIKE 'Standard order%'
ORDER BY sentiment_score DESC;

-- Derive themes and sentiment from the redacted fixture; inspect residual content before reuse.
SELECT
    CASE
        WHEN LOWER(redacted_feedback) LIKE '%refund%'                                          THEN 'Refund'
        WHEN LOWER(redacted_feedback) LIKE '%shipping%' OR LOWER(redacted_feedback) LIKE '%expedited%' THEN 'Shipping'
        WHEN LOWER(redacted_feedback) LIKE '%bulk%'   OR LOWER(redacted_feedback) LIKE '%wholesale%'   THEN 'Bulk Order'
        WHEN LOWER(redacted_feedback) LIKE '%credit card%'                                     THEN 'Payment'
        WHEN LOWER(redacted_feedback) LIKE '%urgent%' OR LOWER(redacted_feedback) LIKE '%privacy%'     THEN 'Urgent'
        ELSE 'General'
    END                                            AS theme,
    COUNT(*)                                       AS feedback_count,
    ROUND(AVG(SNOWFLAKE.CORTEX.SENTIMENT(redacted_feedback)), 3) AS avg_sentiment
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_FEEDBACK_REDACTED
WHERE redacted_feedback NOT LIKE 'Standard order%'
GROUP BY theme
ORDER BY feedback_count DESC;