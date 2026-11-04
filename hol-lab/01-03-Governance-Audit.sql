/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale
Part:         PART 1 - Data Governance
Section:      01-03 - Governance Audit (posture, coverage, lineage, attribution)
Persona:      AGOV_AUDITOR
Story beat:   Governance you cannot see is governance you cannot trust. Because data lives on one
              platform, the full posture is auditable in one place: which policies protect what,
              how much data is classified, the RAW -> GOLD lineage, and (once agents run in Part 2)
              which agent ran which SQL for whom. This is the data-governance audit lens; Part 4
              (04-02) makes these same questions answerable in natural language.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
Diagram:      images/agent-attribution-chain.svg
****************************************************************************************************/

USE ROLE AGOV_AUDITOR;
USE WAREHOUSE AGOV_WH;
USE DATABASE AGENTIC_GOV_DB;
USE SECONDARY ROLES NONE;

USE ROLE AGOV_GOVERNOR;
SHOW DATABASES LIKE 'AGENTIC_GOV_DB';
SET lab_created_at = (SELECT "created_on" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
    WHERE "name" = 'AGENTIC_GOV_DB');
SELECT POLICY_KIND, POLICY_NAME, REF_ENTITY_NAME, POLICY_STATUS
FROM TABLE(AGENTIC_GOV_DB.INFORMATION_SCHEMA.POLICY_REFERENCES(
    REF_ENTITY_NAME => 'AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS',
    REF_ENTITY_DOMAIN => 'TABLE'));
USE ROLE AGOV_AUDITOR;

-- ============================================================================
-- 01-03.1  WHAT POLICIES PROTECT THE DATA?  (governance posture)
-- ============================================================================
SELECT POLICY_KIND,
       COUNT(DISTINCT POLICY_NAME)     AS policies,
       COUNT(DISTINCT REF_ENTITY_NAME) AS protected_objects
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
WHERE POLICY_DB = 'AGENTIC_GOV_DB'
GROUP BY POLICY_KIND
ORDER BY policies DESC;

-- Classification coverage (columns tagged by sensitivity)
SELECT TAG_VALUE AS classification_level, COUNT(*) AS columns_tagged
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE TAG_NAME = 'DATA_CLASSIFICATION' AND OBJECT_DATABASE = 'AGENTIC_GOV_DB' AND DOMAIN = 'COLUMN'
GROUP BY TAG_VALUE
ORDER BY columns_tagged DESC;

-- ============================================================================
-- 01-03.2  RECORDED STRUCTURAL DEPENDENCIES
-- ============================================================================
SELECT REFERENCED_OBJECT_NAME    AS depends_on,
       REFERENCED_OBJECT_DOMAIN  AS source_type,
       REFERENCING_OBJECT_NAME   AS object,
       REFERENCING_OBJECT_DOMAIN AS object_type
FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
WHERE REFERENCED_DATABASE = 'AGENTIC_GOV_DB'
ORDER BY REFERENCING_OBJECT_NAME, REFERENCED_OBJECT_NAME;

-- ============================================================================
-- 01-03.3  AGENT ATTRIBUTION: user + agent + the SQL it ran
--      QUERY_TAG = 'cortex-agent-' || REQUEST_ID is the durable join key.
--      NOTE: this returns rows only AFTER agents have run in Part 2 (02-02 / 02-03).
--      On a first, top-to-bottom pass it is empty by design; re-run this file after
--      Part 2 to see attribution once delivered. Historical metadata can describe a
--      prior lab incarnation; an empty result is not a passing check.
-- ============================================================================
SELECT
    u.START_TIME, u.USER_NAME, u.AGENT_NAME, u.AGENT_ID, u.REQUEST_ID,
    q.QUERY_ID, q.IS_CLIENT_GENERATED_STATEMENT,
    LEFT(q.QUERY_TEXT, 120) AS query_text
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY u
JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  ON  q.QUERY_TAG = CONCAT('cortex-agent-', u.REQUEST_ID)
WHERE u.AGENT_NAME = 'CUSTOMER_INSIGHTS_AGENT'
  AND u.AGENT_DATABASE_NAME = 'AGENTIC_GOV_DB' AND u.AGENT_SCHEMA_NAME = 'AGENTS'
  AND u.START_TIME >= $lab_created_at
ORDER BY u.START_TIME DESC
LIMIT 20;

-- ============================================================================
-- 01-03.4  CLASSIFICATION POSTURE: PROPOSED vs APPLIED DRIFT
--          AGOV_AUDIT_CLASSIFICATION_PROFILE (SILVER/GOLD) has auto_tag=false.
--          Scheduled passes record proposed categories in DATA_CLASSIFICATION_LATEST
--          but never modify tags. This section triggers an immediate audit-only run
--          then surfaces the diff between classifier proposals and applied tags, so
--          the custodian can decide which proposed categories to accept or override.
--
--          SYSTEM$GET_CLASSIFICATION_RESULT('schema.table', 'column') can also
--          retrieve the latest scheduled result for a single column without
--          triggering a new classification pass.
-- ============================================================================

-- Trigger an immediate classification pass on the SILVER DT under the AUDIT profile.
-- auto_tag=false: computes and stores results in DATA_CLASSIFICATION_LATEST
-- without modifying any column tags. Requires CLASSIFICATION_ADMIN (held by AGOV_GOVERNOR).
USE ROLE AGOV_GOVERNOR;
SET classification_started_at = CURRENT_TIMESTAMP();
CALL SYSTEM$CLASSIFY(
    'AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS',
    'AGENTIC_GOV_DB.GOVERNANCE.AGOV_AUDIT_CLASSIFICATION_PROFILE'
);

-- Query DATA_CLASSIFICATION_LATEST for the last classification result.
-- An empty proposal set means NOT READY, not zero drift. Check readiness below first.
-- Subject to ACCOUNT_USAGE latency. Rerun the queries below in this session,
-- retaining classification_started_at, rather than starting another classification.
-- RESULT is a per-table VARIANT keyed by column name, so flatten it to one row per
-- column. SYSTEM$GET_TAG resolves the effective tag value, including SILVER's
-- fail-close schema default; TAG_REFERENCES would only show direct assignments.
-- Rows where the proposed category maps to a different tier need human review.
USE ROLE AGOV_AUDITOR;
SELECT COUNT(*) AS AVAILABLE_CLASSIFICATION_RECORDS,
       MAX(LAST_CLASSIFIED_ON) AS LAST_CLASSIFIED_ON,
       IFF(COUNT(*) = 0, 'PENDING', 'READY') AS READINESS
FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_CLASSIFICATION_LATEST
WHERE DATABASE_NAME = 'AGENTIC_GOV_DB' AND SCHEMA_NAME = 'SILVER'
  AND TABLE_NAME = 'CUSTOMER_ORDER_ANALYTICS' AND STATUS = 'CLASSIFIED'
  AND LAST_CLASSIFIED_ON >= $classification_started_at;
WITH proposals AS (
    SELECT
        f.KEY::STRING AS column_name,
        f.VALUE:recommendation:semantic_category::STRING AS proposed_category,
        f.VALUE:recommendation:coverage::FLOAT AS proposed_coverage,
        CASE
          WHEN f.VALUE:recommendation:semantic_category::STRING IN (
              'EMAIL', 'NATIONAL_IDENTIFIER', 'US_SOCIAL_SECURITY_NUMBER',
              'US_BANK_ACCOUNT_NUMBER', 'PAYMENT_CARD', 'MC_PAYMENT_CARD', 'AMEX_PAYMENT_CARD'
          ) THEN 'PII'
          WHEN f.VALUE:recommendation:semantic_category::STRING IN ('PHONE_NUMBER', 'DATE_OF_BIRTH') THEN 'RESTRICTED'
          WHEN f.VALUE:recommendation:semantic_category::STRING IN ('NAME', 'STREET_ADDRESS', 'POSTAL_CODE', 'ZIP_CODE') THEN 'SENSITIVE'
          WHEN f.VALUE:recommendation:semantic_category::STRING IN (
              'JOB_TITLE', 'OCCUPATION', 'COMPANY', 'CITY', 'US_STATE', 'ADMINISTRATIVE_AREA_1'
          ) THEN 'INTERNAL'
        END AS proposed_tag
    FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_CLASSIFICATION_LATEST c,
         LATERAL FLATTEN(INPUT => c.RESULT) f
    WHERE c.DATABASE_NAME = 'AGENTIC_GOV_DB'
      AND c.SCHEMA_NAME   = 'SILVER'
      AND c.TABLE_NAME    = 'CUSTOMER_ORDER_ANALYTICS'
      AND c.STATUS        = 'CLASSIFIED'
      AND c.LAST_CLASSIFIED_ON >= $classification_started_at
),
applied_tags AS (
    SELECT COLUMN_NAME, TAG_VALUE AS effective_tag
    FROM TABLE(AGENTIC_GOV_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
        'AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS', 'TABLE'
    ))
    WHERE TAG_NAME = 'DATA_CLASSIFICATION'
)
SELECT
    p.column_name,
    p.proposed_category,
    p.proposed_coverage,
    p.proposed_tag,
    a.effective_tag,
    CASE
      WHEN p.proposed_category IS NULL THEN 'NO_PROPOSAL'
      WHEN p.proposed_tag IS NULL THEN 'UNMAPPED_CATEGORY'
      WHEN a.effective_tag IS NULL THEN 'UNTAGGED'
      ELSE 'TAG_MISMATCH'
    END AS drift_status
FROM proposals p
LEFT JOIN applied_tags a
  ON a.COLUMN_NAME = p.column_name
WHERE p.proposed_tag IS NULL
   OR a.effective_tag IS NULL
   OR p.proposed_tag <> a.effective_tag
ORDER BY p.column_name;

-- ============================================================================
-- 01-03.5  CONSENT ENFORCEMENT AUDIT
--          Verifies purpose-based consent governance created in 01-02 section 2.6
--          and 2.10b. Uses Information Schema for real-time checks and Account Usage
--          for delayed policy posture; verify freshness after every reset.
-- ============================================================================

-- --- Real-time INFORMATION_SCHEMA checks (governor - no Account Usage lag) ----
USE ROLE AGOV_GOVERNOR;

-- Tag-based RAP association on the contact activation view.
-- Shows POLICY_KIND, POLICY_NAME, tag columns, and RAP argument columns.
SELECT POLICY_KIND, POLICY_NAME, REF_ENTITY_NAME, REF_ENTITY_DOMAIN,
       POLICY_STATUS, REF_ARG_COLUMN_NAMES,
       TAG_DATABASE, TAG_SCHEMA, TAG_NAME
FROM TABLE(AGENTIC_GOV_DB.INFORMATION_SCHEMA.POLICY_REFERENCES(
    ref_entity_name   => 'AGENTIC_GOV_DB.SILVER.CUSTOMER_CONTACT_ACTIVATION_V',
    ref_entity_domain => 'VIEW'
))
WHERE POLICY_KIND = 'ROW_ACCESS_POLICY';
-- Expect: CUSTOMER_CONTACT_OPTIN_POLICY; TAG_NAME = CONSENT_ENFORCEMENT;
--         POLICY_STATUS = ACTIVE; REF_ARG_COLUMN_NAMES identifies OPTIN.

-- Analytics DT: confirm no row access policy (all customers present).
SELECT COUNT(*) AS analytics_rap_count
FROM TABLE(AGENTIC_GOV_DB.INFORMATION_SCHEMA.POLICY_REFERENCES(
    ref_entity_name   => 'AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS',
    ref_entity_domain => 'TABLE'
))
WHERE POLICY_KIND = 'ROW_ACCESS_POLICY';
-- Expect: 0  (analytics DT has no row access policy; all customers are present).

-- Effective CONSENT_ENFORCEMENT tag on the contact view. SYSTEM$GET_TAG uses
-- TABLE for every table-like object, including views, and requires DESCRIBE-like
-- access to the object, so run this owner check as the governor.
SELECT SYSTEM$GET_TAG(
    'AGENTIC_GOV_DB.GOVERNANCE.CONSENT_ENFORCEMENT',
    'AGENTIC_GOV_DB.SILVER.CUSTOMER_CONTACT_ACTIVATION_V',
    'TABLE'
) AS consent_tag_value;
-- Expect: CONTACT_OPT_IN_REQUIRED

-- Contact view: verify zero non-consented rows (aggregate count only - no PII).
-- Run as contact activator: the RAP requires an active entitlement; governor does not
-- hold one and would see zero rows regardless, making the check indistinguishable
-- from a genuine RAP block. Contact activator holds the entitlement and OPTIN=TRUE
-- rows are visible; non-consented rows are filtered by the tag-based RAP.
USE ROLE AGOV_CONTACT_ACTIVATOR;
USE WAREHOUSE AGOV_WH;
SELECT COUNT(*) AS invalid_optin_rows
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_CONTACT_ACTIVATION_V
WHERE NOT COALESCE(OPTIN, FALSE);
-- Expect: 0  (tag-based RAP filters all non-consented rows at query time).

-- --- Auditor posture checks (GOVERNANCE_VIEWER allows ACCOUNT_USAGE and SYSTEM$ calls) ---
USE ROLE AGOV_AUDITOR;
USE WAREHOUSE AGOV_WH;

-- Entitlement posture (auditor has SELECT on POLICY_ENTITLEMENTS from 01-02).
-- Aggregate output only: no entitlement-row PII beyond names.
SELECT ENTITLEMENT_NAME, PRINCIPAL_TYPE, IS_ENABLED,
       COUNT(*) AS row_count
FROM AGENTIC_GOV_DB.GOVERNANCE.POLICY_ENTITLEMENTS
GROUP BY ENTITLEMENT_NAME, PRINCIPAL_TYPE, IS_ENABLED
ORDER BY ENTITLEMENT_NAME;
-- Expect: CONTACT_ACTIVATION / ACCOUNT_ROLE / TRUE / 1

-- Delayed tag-based RAP posture via ACCOUNT_USAGE; not a current-state acceptance check.
-- CUSTOMER_ORDER_ANALYTICS must NOT appear: analytics DT carries no row access policy.
SELECT POLICY_KIND, POLICY_NAME, REF_ENTITY_NAME, POLICY_STATUS,
       REF_ARG_COLUMN_NAMES, TAG_DATABASE, TAG_SCHEMA, TAG_NAME
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
WHERE POLICY_DB      = 'AGENTIC_GOV_DB'
  AND REF_SCHEMA_NAME = 'SILVER'
  AND POLICY_KIND    = 'ROW_ACCESS_POLICY'
ORDER BY REF_ENTITY_NAME;
-- Expect: CUSTOMER_CONTACT_OPTIN_POLICY on CUSTOMER_CONTACT_ACTIVATION_V (tag-based);
--         CUSTOMER_ORDER_ANALYTICS absent from results.
