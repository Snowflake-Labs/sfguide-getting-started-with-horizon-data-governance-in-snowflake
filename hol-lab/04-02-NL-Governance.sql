/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale
Part:         PART 4 - AI-Assisted Governance (use AI to help govern)
Section:      04-02 - Natural-language governance for governors
Persona:      AGOV_AUDITOR (04-02.1), AGOV_ANALYST then AGOV_GOVERNOR (04-02.2)
Story beat:   The governance posture, lineage, and attribution audited with SQL in Part 1 (01-03)
              are also answerable in plain English. Governance metadata questions go to Cortex
              Code in Snowsight, which writes the ACCOUNT_USAGE / INFORMATION_SCHEMA SQL. Business
              questions go to Cortex Analyst over the governed GOLD semantic view.
Before:       02-04.6 RSS cleanup done, then a fresh Snowflake session and CoCo chat.
Execution:    Manual. The SQL below only sets worksheet context. It does NOT select the role
              of the UI session. Set the role named in each step in that interface itself.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
Diagram:      images/agent-attribution-chain.svg
****************************************************************************************************/

USE ROLE AGOV_AUDITOR;
USE WAREHOUSE AGOV_WH;
USE DATABASE AGENTIC_GOV_DB;
USE SECONDARY ROLES NONE;

-- ============================================================================
-- 04-02.1  ASK THE PART 1 AUDIT QUESTIONS IN NATURAL LANGUAGE (Cortex Code)
--      UI role: AGOV_AUDITOR. Set it as the Snowsight session role before you open
--      Cortex Code, and confirm it in the interface.
--      Ask governance metadata questions - Cortex Code writes the SQL against
--      ACCOUNT_USAGE / INFORMATION_SCHEMA for you:
--        - "Which columns in AGENTIC_GOV_DB are classified as PII?"
--        - "What masking and row access policies protect the CUSTOMER table?"
--        - "Show every SQL statement the CUSTOMER_INSIGHTS_AGENT ran and who triggered it."
--        - "What is the lineage from CUSTOMER_RAW to the GOLD semantic view?"
--      Check each answer against the 01-03 SQL results, not the model's wording.
-- ============================================================================

-- ============================================================================
-- 04-02.2  ASK BUSINESS QUESTIONS UNDER GOVERNANCE (Cortex Analyst over GOLD)
--      UI role: AGOV_ANALYST first, then AGOV_GOVERNOR for comparison. In Snowflake
--      CoWork, set the role, select CUSTOMER_INSIGHTS_AGENT (its tool is the GOLD
--      semantic view), and start a NEW conversation for each role.
--      The governed GOLD semantic view answers business questions under each role's
--      policies - revenue by state, AOV, orders by currency - the same masking,
--      aggregation, and projection boundaries proven in Part 2 (02-02) apply.
--      Analytics has no row access policy, so every role sees the full customer
--      population.
-- ============================================================================
-- Example to ask in natural language (Cortex Analyst generates the SQL):
--   "What is total revenue by state?"  ->  bounded by the caller's masking/aggregation policies.
--   STATE/CURRENCY are INTERNAL and remain readable for both personas.
--   Record the UI questions as NOT RUN until they have been exercised in an identified
--   interface with the stated role.
