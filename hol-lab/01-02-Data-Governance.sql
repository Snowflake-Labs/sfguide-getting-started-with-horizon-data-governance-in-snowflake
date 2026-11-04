/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale
Part:         PART 1 - Data Governance
Section:      01-02 - Data Governance + the governed GOLD semantic view
Persona:      AGOV_GOVERNOR (data custodian)
Story beat:   "Do not invent a separate AI data-governance universe." Classify once, mask by
              classification, and add row/aggregation/projection controls. Everything here is
              deterministic RBAC + FGAC - the seatbelts. Tags propagate to SILVER so derived
              analytics inherit protection automatically, then we publish the governed GOLD
              semantic view. This base is what AI inherits later in Part 2.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
****************************************************************************************************/

-- ============================================================================
-- 2.0  BASELINE: analyst has no BRONZE access (RBAC keeps consumers off source layers)
-- ============================================================================
USE ROLE AGOV_ANALYST;
USE WAREHOUSE AGOV_WH;
USE DATABASE AGENTIC_GOV_DB;
-- Pin the session to a single role for the whole script so the IS_ROLE_IN_SESSION checks in the masking policies (created below) resolve deterministically during validation.
-- This persists across the USE ROLE switches in this file.
-- Snowsight Data Preview defaults to USE SECONDARY ROLES ALL. Because AGOV_ENGINEER/GOVERNOR are in your role hierarchy via SYSADMIN, the masking policies' exempt branch fires even when your primary role is AGOV_ANALYST, so Data Preview shows clear-text. 00-Setup sets DEFAULT_SECONDARY_ROLES = () on your user to fix this for the whole lab session.

-- If you are running a standalone worksheet, run USE SECONDARY ROLES NONE first.
USE SECONDARY ROLES NONE;

-- AGOV_ANALYST cannot read BRONZE. Run this separately only when presenting
-- the expected RBAC failure; leaving it out keeps this executable lab script
-- running through the governance setup and its validations.
-- SELECT FIRST_NAME, LAST_NAME, EMAIL, SSN, PHONE_NUMBER, CREDITCARD, STATE
-- FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER
-- LIMIT 5;

-- ============================================================================
-- 2.1  ENTERPRISE CLASSIFICATION TAG (5-tier taxonomy, propagating)
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
USE SCHEMA AGENTIC_GOV_DB.GOVERNANCE;

CREATE TAG IF NOT EXISTS AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION
    ALLOWED_VALUES 'PII', 'RESTRICTED', 'SENSITIVE', 'INTERNAL', 'PUBLIC'
    COMMENT = 'Enterprise data classification; drives tag-based masking; propagates downstream'
    PROPAGATE = ON_DEPENDENCY_AND_DATA_MOVEMENT;

-- The pipeline owner applies the EMAIL_DOMAIN classification inline in the DT
-- definition. Scope this ability to the one governance tag rather than granting
-- account-level APPLY TAG to the service role.
GRANT APPLY ON TAG AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION
    TO ROLE AGOV_PIPELINE_SERVICE_ROLE;


-- ============================================================================
-- 2.2  CLASSIFICATION PROFILE WITH TAG MAP (native Snowflake semantic categories -> our tag)
-- ============================================================================
-- BRONZE profile: auto_tag=true (preventive enforcement)
-- New BRONZE tables are classified on schedule and tagged with data classification automatically.
CREATE SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE IF NOT EXISTS
    AGOV_BRONZE_CLASSIFICATION_PROFILE(
    {
      'minimum_object_age_for_classification_days': 0,
      'maximum_classification_validity_days': 30,
      'auto_tag': true,
      'tag_map': {
        'column_tag_map': [
          { 'tag_name': 'AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION',
            'tag_value': 'PII',
            'semantic_categories': ['EMAIL','NATIONAL_IDENTIFIER','US_SOCIAL_SECURITY_NUMBER',
                                    'US_BANK_ACCOUNT_NUMBER',
                                    'PAYMENT_CARD',
                                    'MC_PAYMENT_CARD','AMEX_PAYMENT_CARD'] },
          { 'tag_name': 'AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION',
            'tag_value': 'RESTRICTED',
            'semantic_categories': ['PHONE_NUMBER','DATE_OF_BIRTH'] },
          { 'tag_name': 'AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION',
            'tag_value': 'SENSITIVE',
            'semantic_categories': ['NAME','STREET_ADDRESS','POSTAL_CODE','ZIP_CODE'] },
          { 'tag_name': 'AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION',
            'tag_value': 'INTERNAL',
            'semantic_categories': ['JOB_TITLE','OCCUPATION','COMPANY','CITY','US_STATE','ADMINISTRATIVE_AREA_1'] }
        ]
      }
    });

-- AUDIT profile: auto_tag=false (review-only)
-- Classification runs on schedule for SILVER and GOLD schemas and stores results in
-- DATA_CLASSIFICATION_LATEST but never auto-applies tags. The custodian reviews
-- proposed-vs-applied drift in 01-03 and applies tags deliberately.
-- No custom classifiers: SILVER/GOLD derived columns are governed by tag propagation
-- from BRONZE, not raw value patterns.
CREATE SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE IF NOT EXISTS
    AGOV_AUDIT_CLASSIFICATION_PROFILE(
    {
      'minimum_object_age_for_classification_days': 0,
      'maximum_classification_validity_days': 90,
      'auto_tag': false,
      'tag_map': {
        'column_tag_map': [
          { 'tag_name': 'AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION',
            'tag_value': 'PII',
            'semantic_categories': ['EMAIL','NATIONAL_IDENTIFIER','US_SOCIAL_SECURITY_NUMBER',
                                    'US_BANK_ACCOUNT_NUMBER',
                                    'PAYMENT_CARD',
                                    'MC_PAYMENT_CARD','AMEX_PAYMENT_CARD'] },
          { 'tag_name': 'AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION',
            'tag_value': 'RESTRICTED',
            'semantic_categories': ['PHONE_NUMBER','DATE_OF_BIRTH'] },
          { 'tag_name': 'AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION',
            'tag_value': 'SENSITIVE',
            'semantic_categories': ['NAME','STREET_ADDRESS','POSTAL_CODE','ZIP_CODE'] },
          { 'tag_name': 'AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION',
            'tag_value': 'INTERNAL',
            'semantic_categories': ['JOB_TITLE','OCCUPATION','COMPANY','CITY','US_STATE','ADMINISTRATIVE_AREA_1'] }
        ]
      }
    });

-- Attach profiles at schema scope. BRONZE gets the preventive auto-tagging profile;
-- SILVER and GOLD get the audit-only review profile. No database-wide profile: the
-- split lets BRONZE enforce preventively while keeping SILVER/GOLD under custodian review.
ALTER SCHEMA AGENTIC_GOV_DB.BRONZE
    SET CLASSIFICATION_PROFILE = 'AGENTIC_GOV_DB.GOVERNANCE.AGOV_BRONZE_CLASSIFICATION_PROFILE';
ALTER SCHEMA AGENTIC_GOV_DB.SILVER
    SET CLASSIFICATION_PROFILE = 'AGENTIC_GOV_DB.GOVERNANCE.AGOV_AUDIT_CLASSIFICATION_PROFILE';
ALTER SCHEMA AGENTIC_GOV_DB.GOLD
    SET CLASSIFICATION_PROFILE = 'AGENTIC_GOV_DB.GOVERNANCE.AGOV_AUDIT_CLASSIFICATION_PROFILE';

-- ============================================================================
-- 2.3  CUSTOM CLASSIFIERS (CREDITCARD and COMPANY patterns; BRONZE profile only)
-- ============================================================================
-- Credit-card number patterns (Mastercard, Amex)
CREATE OR REPLACE SNOWFLAKE.DATA_PRIVACY.CUSTOM_CLASSIFIER CREDITCARD();
CALL AGENTIC_GOV_DB.GOVERNANCE.CREDITCARD!ADD_REGEX('MC_PAYMENT_CARD','IDENTIFIER','^(?:5[1-5][0-9]{2}|222[1-9]|22[3-9][0-9]|2[3-6][0-9]{2}|27[01][0-9]|2720)[0-9]{12}$');
CALL AGENTIC_GOV_DB.GOVERNANCE.CREDITCARD!ADD_REGEX('AMEX_PAYMENT_CARD','IDENTIFIER','^3[4-7][0-9]{13}$');

-- COMPANY: no native Snowflake semantic category exists for free-form business trading
-- names (the full taxonomy covers NAME, OCCUPATION, ADMINISTRATIVE_AREA_1, and structured
-- IDs, but not company names). Values themselves carry no structural signal ("Snowflake",
-- "Acme Corp"), so VALUE_REGEX can't discriminate on content - instead it's intentionally
-- permissive (matches any non-empty string) and COL_NAME_REGEX does the real work,
-- classifying by column name alone. This keeps COMPANY category-and-tag-driven through the
-- same SYSTEM$CLASSIFY + tag_map pipeline as every other column, instead of a hard-coded
-- per-column SET TAG override.
CREATE OR REPLACE SNOWFLAKE.DATA_PRIVACY.CUSTOM_CLASSIFIER COMPANY_NAME();
CALL AGENTIC_GOV_DB.GOVERNANCE.COMPANY_NAME!ADD_REGEX(
    SEMANTIC_CATEGORY => 'COMPANY',
    PRIVACY_CATEGORY  => 'QUASI_IDENTIFIER',
    VALUE_REGEX       => '^.+$',
    COL_NAME_REGEX    => '^COMPANY$',
    DESCRIPTION       => 'Business/company trading name; column-name-driven (no reliable value pattern for free-form names)');

-- Register custom classifiers on the BRONZE profile so scheduled auto-classification
-- also evaluates them. The AUDIT profile (SILVER/GOLD) registers no custom classifiers:
-- those schemas are governed by tag propagation from BRONZE, not raw value patterns.
CALL AGENTIC_GOV_DB.GOVERNANCE.AGOV_BRONZE_CLASSIFICATION_PROFILE!SET_CUSTOM_CLASSIFIERS(
    {
      'AGENTIC_GOV_DB.GOVERNANCE.CREDITCARD':   AGENTIC_GOV_DB.GOVERNANCE.CREDITCARD!LIST(),
      'AGENTIC_GOV_DB.GOVERNANCE.COMPANY_NAME': AGENTIC_GOV_DB.GOVERNANCE.COMPANY_NAME!LIST()
    });

-- ============================================================================
-- 2.4  CLASSIFY BRONZE.CUSTOMER (immediate; BRONZE profile auto_tag applies DATA_CLASSIFICATION)
-- ============================================================================
-- Immediate pass for BRONZE.CUSTOMER under the BRONZE profile (auto_tag=true, validity=30).
-- Speeds up the lab by not waiting for the scheduled pass. Custom classifiers
-- (CREDITCARD, COMPANY_NAME) are registered on this profile and run here.
CALL SYSTEM$CLASSIFY('AGENTIC_GOV_DB.BRONZE.CUSTOMER', 'AGENTIC_GOV_DB.GOVERNANCE.AGOV_BRONZE_CLASSIFICATION_PROFILE');

-- Validate applied classifications
SELECT COLUMN_NAME, TAG_VALUE AS classification_level
FROM TABLE(AGENTIC_GOV_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('AGENTIC_GOV_DB.BRONZE.CUSTOMER','table'))
WHERE TAG_NAME = 'DATA_CLASSIFICATION'
ORDER BY CASE TAG_VALUE WHEN 'PII' THEN 1 WHEN 'RESTRICTED' THEN 2 WHEN 'SENSITIVE' THEN 3 WHEN 'INTERNAL' THEN 4 ELSE 5 END, COLUMN_NAME;

-- ============================================================================
-- 2.4b CLASSIFY BRONZE.CUSTOMER_ORDERS (business transaction data)
--      CUSTOMER_ORDERS contains no personal data; SYSTEM$CLASSIFY won't detect
--      anything meaningful on these columns. Rather than tag each column
--      individually, set ONE table-level default: DATA_CLASSIFICATION tags
--      support inheritance - TAG_REFERENCES_ALL_COLUMNS
--      resolves untagged columns to the nearest ancestor's tag value), so a
--      single table-level tag applies to every column, including any added
--      later, with no per-column maintenance. This is the same fail-close
--      default pattern used at the SILVER schema level in section 2.7 - just
--      scoped to this one table instead of the whole schema, since BRONZE
--      also holds CUSTOMER, which needs granular per-column classification
--      and must not inherit a blanket INTERNAL default.
--      Propagation (PROPAGATE = ON_DEPENDENCY_AND_DATA_MOVEMENT) carries this
--      table-level default down to derived views/DTs at the per-column level
--      just like an explicit column tag would - confirmed via a sandbox test
--      against both a view and a dynamic table before applying here.
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
ALTER TABLE AGENTIC_GOV_DB.BRONZE.CUSTOMER_ORDERS
    SET TAG AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION = 'INTERNAL';

-- ============================================================================
-- SNOWSIGHT: See classification tags applied to each column
--   Data > Databases > AGENTIC_GOV_DB > BRONZE > CUSTOMER > Columns tab
--
--   Each classified column shows a DATA_CLASSIFICATION tag chip with its tier:
--     PII        EMAIL, SSN, CREDITCARD
--     RESTRICTED PHONE_NUMBER, BIRTHDATE
--     SENSITIVE  FIRST_NAME, LAST_NAME, STREET_ADDRESS, ZIP
--     INTERNAL   CITY, STATE, COMPANY, JOB
--
--   CITY: matched by the CITY semantic category.
--   STATE: matched by ADMINISTRATIVE_AREA_1 (the built-in geo category for states/provinces).
--   CREDITCARD: matched by PAYMENT_CARD (native category) and MC_PAYMENT_CARD/AMEX_PAYMENT_CARD
--     (custom CREDITCARD classifier outputs). Both are mapped to PII in the tag_map.
--   ZIP: matched by POSTAL_CODE (native category detected by the classifier). ZIP_CODE is also
--     kept in the tag_map as an alias for forward compatibility.
--   COMPANY: matched by the custom COMPANY_NAME classifier's COMPANY category (column-name
--     driven, section 2.3) - no longer a hard-coded SET TAG override.
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
-- ============================================================================
-- 2.4c UNMASK ACCESS ROLE
--      A single database role - the semantic "may bypass masking" capability -
--      granted to whichever functional/service roles need it. Part 2 adds the
--      AGENTIC_UNMASK_ACCESS account-role co-clearance: UNMASK_ACCESS remains
--      necessary, but is no longer sufficient for clear text inside an agent session.
-- ============================================================================
CREATE DATABASE ROLE IF NOT EXISTS AGENTIC_GOV_DB.UNMASK_ACCESS
    COMMENT = 'Capability: may bypass tag-based masking. Granted to AGOV_GOVERNOR and AGOV_PIPELINE_SERVICE_ROLE';
GRANT DATABASE ROLE AGENTIC_GOV_DB.UNMASK_ACCESS TO ROLE AGOV_GOVERNOR;
GRANT DATABASE ROLE AGENTIC_GOV_DB.UNMASK_ACCESS TO ROLE AGOV_PIPELINE_SERVICE_ROLE;

-- ============================================================================
-- 2.4d TWO MORE CAPABILITY ROLES
--      AGOV_ENGINEER is "subject only to masking but else unconstrained": it
--      needs to see the true shape of the data (ungrouped, every column
--      projectable) to do its job, but must never see unmasked column VALUES.
--      So AGOV_ENGINEER gets these two bypass capabilities but never
--      UNMASK_ACCESS. AGOV_GOVERNOR and AGOV_PIPELINE_SERVICE_ROLE get all
--      three - governor because it is exempt from masking/aggregation/projection
--      by design, the service role because it must be able to CREATE objects
--      referencing sensitive columns without being blocked. AGOV_ANALYST holds
--      none - subject to aggregation, masking, and projection with zero bypass.
--      Row-access bypass (ALL_ROWS_ACCESS) no longer exists: analytics DT has
--      no row access policy; consent enforcement is scoped to the contact
--      activation view only (CUSTOMER_CONTACT_ACTIVATION_V, section 2.10b).
-- ============================================================================

CREATE DATABASE ROLE IF NOT EXISTS AGENTIC_GOV_DB.UNAGGREGATED_ACCESS
    COMMENT = 'Capability: may bypass the aggregation policy (read individual rows, no MIN_GROUP_SIZE). Granted to AGOV_GOVERNOR, AGOV_PIPELINE_SERVICE_ROLE, AGOV_ENGINEER - never to AGOV_ANALYST.';
GRANT DATABASE ROLE AGENTIC_GOV_DB.UNAGGREGATED_ACCESS TO ROLE AGOV_GOVERNOR;
GRANT DATABASE ROLE AGENTIC_GOV_DB.UNAGGREGATED_ACCESS TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT DATABASE ROLE AGENTIC_GOV_DB.UNAGGREGATED_ACCESS TO ROLE AGOV_ENGINEER;

CREATE DATABASE ROLE IF NOT EXISTS AGENTIC_GOV_DB.UNRESTRICTED_PROJECTION_ACCESS
    COMMENT = 'Capability: may bypass the projection policy (project any protected column, e.g. ZIP). Granted to AGOV_GOVERNOR, AGOV_PIPELINE_SERVICE_ROLE, AGOV_ENGINEER - never to AGOV_ANALYST.';
GRANT DATABASE ROLE AGENTIC_GOV_DB.UNRESTRICTED_PROJECTION_ACCESS TO ROLE AGOV_GOVERNOR;
GRANT DATABASE ROLE AGENTIC_GOV_DB.UNRESTRICTED_PROJECTION_ACCESS TO ROLE AGOV_PIPELINE_SERVICE_ROLE;
GRANT DATABASE ROLE AGENTIC_GOV_DB.UNRESTRICTED_PROJECTION_ACCESS TO ROLE AGOV_ENGINEER;

-- ============================================================================
-- 2.5  MULTI-TYPE TAG-BASED MASKING (one policy per data type, all on one tag)
--      Masking policies are type-specific; attach all to DATA_CLASSIFICATION.
--      Named MASK_BY_CLASSIFICATION_* (not MASK_STRING/MASK_DATE) - the name now
--      says WHAT drives the masking decision (the DATA_CLASSIFICATION tag tier),
--      not just the data type the policy signature happens to accept.
-- ============================================================================
CREATE OR REPLACE MASKING POLICY AGENTIC_GOV_DB.GOVERNANCE.MASK_BY_CLASSIFICATION_STRING AS (VAL STRING) RETURNS STRING ->
  CASE
    -- ACCOUNTADMIN is a separate hard-coded break-glass check. Everyone else's
    -- exemption is keyed off the UNMASK_ACCESS database role (2.4c) AGOV_ENGINEER doesn't
    -- hold UNMASK_ACCESS, so it falls through to the tag-based
    -- branches below even though it has ordinary SELECT on BRONZE.
    WHEN IS_ROLE_IN_SESSION('ACCOUNTADMIN')
      OR IS_DATABASE_ROLE_IN_SESSION('UNMASK_ACCESS') THEN VAL
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION') = 'PII'        THEN '***PII-REDACTED***'
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION') = 'RESTRICTED' THEN CONCAT('***-', RIGHT(VAL, 4))
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION') = 'SENSITIVE'  THEN SHA2(VAL, 256)
    ELSE VAL
  END
  COMMENT = 'Tag-based string masking by DATA_CLASSIFICATION tier. Baseline exemption is keyed off the UNMASK_ACCESS database role (2.4c). Part 2 (02-03) requires the additional AGENTIC_UNMASK_ACCESS co-clearance during agent execution.';

CREATE OR REPLACE MASKING POLICY AGENTIC_GOV_DB.GOVERNANCE.MASK_BY_CLASSIFICATION_DATE AS (VAL DATE) RETURNS DATE ->
  CASE
    WHEN IS_ROLE_IN_SESSION('ACCOUNTADMIN')
      OR IS_DATABASE_ROLE_IN_SESSION('UNMASK_ACCESS') THEN VAL
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION') = 'PII'        THEN NULL
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION') = 'RESTRICTED' THEN DATE_TRUNC('YEAR', VAL)
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION') = 'SENSITIVE'  THEN DATE_TRUNC('MONTH', VAL)
    ELSE VAL
  END
  COMMENT = 'Tag-based date masking by DATA_CLASSIFICATION tier. Baseline exemption is keyed off the UNMASK_ACCESS database role (2.4c). Part 2 (02-03) requires the additional AGENTIC_UNMASK_ACCESS co-clearance during agent execution.';

-- Attach both type policies to the single classification tag
ALTER TAG AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION SET MASKING POLICY AGENTIC_GOV_DB.GOVERNANCE.MASK_BY_CLASSIFICATION_STRING;
ALTER TAG AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION SET MASKING POLICY AGENTIC_GOV_DB.GOVERNANCE.MASK_BY_CLASSIFICATION_DATE;

-- ============================================================================
-- SNOWSIGHT: Masking policies are now live on every classified column
--   Governance > Tags & Policies > Tagged Objects
--     Filter Object Type: Columns   Filter Database: AGENTIC_GOV_DB
--     Each classified BRONZE.CUSTOMER column now shows a Masking Policy
--     (MASK_BY_CLASSIFICATION_STRING or MASK_BY_CLASSIFICATION_DATE) in the Policy column alongside its tag value.
--   Governance > Tags & Policies > Dashboard
--     DATA_CLASSIFICATION appears in Tag Prevalence.
--     Masking Policy coverage counts reflect MASK_BY_CLASSIFICATION_STRING and MASK_BY_CLASSIFICATION_DATE.
--   Data > Databases > AGENTIC_GOV_DB > BRONZE > CUSTOMER > Columns tab
--     The Masking Policy column now shows MASK_BY_CLASSIFICATION_STRING or MASK_BY_CLASSIFICATION_DATE per row.
--
--   Note: the Dashboard refreshes for tagged Objects has up to 2h
--   latency. The SQL query in 2.4 is the authoritative real-time view during a
--   live HOL session.
-- ============================================================================

-- ============================================================================
-- 2.5a TAG LINEAGE PRECEDENCE: DATABASE -> SCHEMA -> COLUMN
--      Tag-based masking resolves the NEAREST tag in the lineage; the most
--      specific wins. We walk the three levels as a teaching exercise using
--      AGOV_ENGINEER (BRONZE access, subject to masking but not ANALYST who has
--      no BRONZE access at all — see 00-Setup).
--
--      Design principle: BRONZE is RBAC-gated. Only privileged roles reach it,
--      so column-level tags are sufficient for correct enforcement.
--      Schema/database defaults on BRONZE are pedagogical here — we set them
--      temporarily and unset both after the demo. The fail-close schema default
--      lives on SILVER (section 2.7) where consumer access is broad.
-- ============================================================================

-- LEVEL 1 - DATABASE (most restrictive). Every column in every schema inherits
-- PII unless a more specific tag overrides it. Anything unclassified anywhere
-- in the database is fully redacted.
USE ROLE AGOV_GOVERNOR;
ALTER DATABASE AGENTIC_GOV_DB
    SET TAG AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION = 'PII';
SELECT SYSTEM$GET_TAG('AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION',
    'AGENTIC_GOV_DB', 'DATABASE') AS database_default_tier;   -- PII

USE ROLE AGOV_ENGINEER;
SELECT 'DB=PII' AS level, CREDITCARD, EMAIL, JOB
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER LIMIT 5;
--   CREDITCARD -> ***PII-REDACTED***  (column tag PII overrides DB, same result)
--   EMAIL      -> ***PII-REDACTED***  (column tag PII)   JOB -> raw (column INTERNAL)

-- LEVEL 2 - SCHEMA. A schema-level tag overrides the database value for columns
-- in that schema. Setting BRONZE to SENSITIVE relaxes the DB catch-all to SHA2
-- for any column that doesn't carry its own column-level tag.
USE ROLE AGOV_GOVERNOR;
ALTER SCHEMA AGENTIC_GOV_DB.BRONZE
    SET TAG AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION = 'SENSITIVE';
SELECT SYSTEM$GET_TAG('AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION',
    'AGENTIC_GOV_DB.BRONZE', 'SCHEMA') AS schema_default_tier;   -- SENSITIVE

USE ROLE AGOV_ENGINEER;
SELECT 'SCHEMA=SENSITIVE' AS level, CREDITCARD, EMAIL, JOB
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER LIMIT 5;
--   CREDITCARD -> ***PII-REDACTED***  (column tag PII wins over SCHEMA=SENSITIVE)
--   EMAIL      -> ***PII-REDACTED***  (column tag PII)
--   JOB        -> raw (column INTERNAL overrides SCHEMA=SENSITIVE)

-- LEVEL 3 - COLUMN (most specific). Column tags from 2.4 override both the
-- database and schema values. Every classified column resolves to its own tier.
SELECT 'COLUMN' AS level, EMAIL, PHONE_NUMBER, CITY, JOB, CREDITCARD
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER LIMIT 5;
--   EMAIL        -> ***PII-REDACTED*** (PII column tag)
--   PHONE_NUMBER -> ***-last4          (RESTRICTED column tag)
--   CREDITCARD   -> ***PII-REDACTED*** (PII column tag — explicitly set in 2.4)
--   CITY         -> raw               (INTERNAL column tag overrides SCHEMA=SENSITIVE)
--   JOB          -> raw               (INTERNAL column tag)

-- Unset both demonstration defaults. BRONZE is RBAC-gated; column-level tags
-- are sufficient for correct enforcement there. The fail-close schema default
-- is only needed on SILVER where broad consumer access happens (section 2.7).
USE ROLE AGOV_GOVERNOR;
ALTER DATABASE AGENTIC_GOV_DB
    UNSET TAG AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION;
ALTER SCHEMA AGENTIC_GOV_DB.BRONZE
    UNSET TAG AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION;
-- Masking is DATA-TYPE scoped: the tag is inherited by every column, but only
-- columns whose type matches a policy on the tag are masked. OPTIN (BOOLEAN)
-- and ID (FLOAT/NUMBER) carry the tag yet stay in the clear — only STRING/DATE
-- policies exist. OPTIN is later used as the row access policy argument only on
-- the purpose-specific contact activation view.

-- ============================================================================
-- 2.6  PURPOSE-BASED CONSENT GOVERNANCE (contact activation only)
--      CUSTOMER_ORDER_ANALYTICS includes ALL customers: masking, aggregation,
--      and projection govern data quality on analytics. Row-level opt-in consent
--      is scoped to the CONTACT_ACTIVATION purpose only.
--
--      Architecture:
--        POLICY_ENTITLEMENTS     governor-owned table: which roles may use
--                                which purpose. A new purpose = a new row.
--        CONSENT_ENFORCEMENT     tag applied to surfaces where OPTIN=TRUE AND
--                                an active entitlement are BOTH required
--                                (tag-based RAP; Enterprise+ Preview, mid-2026).
--        CUSTOMER_CONTACT_OPTIN_POLICY  tag-based RAP: requires OPTIN=TRUE AND
--                                a CONTACT_ACTIVATION entitlement for the calling
--                                role. No consent bypass even for entitled roles;
--                                entitlement + opt-in are both mandatory.
--                                ACCOUNTADMIN bypasses the entitlement lookup
--                                only; OPTIN=TRUE is required for every row.
--
-- ============================================================================
USE ROLE AGOV_GOVERNOR;

-- Entitlement table: governor-owned in GOVERNANCE schema.
CREATE OR REPLACE TABLE AGENTIC_GOV_DB.GOVERNANCE.POLICY_ENTITLEMENTS (
    ENTITLEMENT_NAME VARCHAR  COMMENT 'Purpose identifier, e.g. CONTACT_ACTIVATION',
    PRINCIPAL_TYPE   VARCHAR  COMMENT 'ACCOUNT_ROLE',
    PRINCIPAL_NAME   VARCHAR  COMMENT 'Role name checked with IS_ROLE_IN_SESSION',
    IS_ENABLED       BOOLEAN  COMMENT 'Toggle off without deleting the row',
    COMMENT          VARCHAR
);

INSERT INTO AGENTIC_GOV_DB.GOVERNANCE.POLICY_ENTITLEMENTS
    (ENTITLEMENT_NAME, PRINCIPAL_TYPE, PRINCIPAL_NAME, IS_ENABLED, COMMENT)
VALUES
    ('CONTACT_ACTIVATION', 'ACCOUNT_ROLE', 'AGOV_CONTACT_ACTIVATOR', TRUE,
     'Contact activation entitlement for AGOV_CONTACT_ACTIVATOR');

-- Auditor needs SELECT to verify entitlement posture in 01-03.
GRANT SELECT ON TABLE AGENTIC_GOV_DB.GOVERNANCE.POLICY_ENTITLEMENTS TO ROLE AGOV_AUDITOR;

-- CONSENT_ENFORCEMENT tag: separate axis from DATA_CLASSIFICATION.
-- IF NOT EXISTS because a tag with an attached policy/object cannot be OR REPLACE'd;
-- reruns would fail. Use IF NOT EXISTS for safe idempotent execution.
CREATE TAG IF NOT EXISTS AGENTIC_GOV_DB.GOVERNANCE.CONSENT_ENFORCEMENT
    ALLOWED_VALUES 'CONTACT_OPT_IN_REQUIRED'
    COMMENT = 'Purpose-specific consent enforcement. Apply to surfaces where OPTIN=TRUE and an active entitlement are both required. Drives a tag-based row access policy.';

-- Governor already holds APPLY TAG ON ACCOUNT (00-Setup 0.7); explicit grant for clarity.
GRANT APPLY ON TAG AGENTIC_GOV_DB.GOVERNANCE.CONSENT_ENFORCEMENT TO ROLE AGOV_GOVERNOR;

-- Consent row access policy: both OPTIN=TRUE and an active entitlement are mandatory.
-- No row-bypass for the entitled role; entitlement + opt-in are independently required.
-- ACCOUNTADMIN bypasses only the entitlement lookup; it still requires OPTIN=TRUE.
CREATE OR REPLACE ROW ACCESS POLICY AGENTIC_GOV_DB.GOVERNANCE.CUSTOMER_CONTACT_OPTIN_POLICY
    AS (OPTIN_STATUS BOOLEAN) RETURNS BOOLEAN ->
      COALESCE(OPTIN_STATUS, FALSE)
      AND (
          IS_ROLE_IN_SESSION('ACCOUNTADMIN')
          OR EXISTS (
              SELECT 1
              FROM AGENTIC_GOV_DB.GOVERNANCE.POLICY_ENTITLEMENTS E
              WHERE E.ENTITLEMENT_NAME = 'CONTACT_ACTIVATION'
                AND E.PRINCIPAL_TYPE  = 'ACCOUNT_ROLE'
                AND E.IS_ENABLED      = TRUE
                AND IS_ROLE_IN_SESSION(E.PRINCIPAL_NAME)
          )
      );

-- Associate the RAP with the CONSENT_ENFORCEMENT tag.
-- When the tag is applied to a table or view, Snowflake finds the OPTIN column at
-- query time and passes it as OPTIN_STATUS to the policy.
ALTER TAG AGENTIC_GOV_DB.GOVERNANCE.CONSENT_ENFORCEMENT
    SET ROW ACCESS POLICY AGENTIC_GOV_DB.GOVERNANCE.CUSTOMER_CONTACT_OPTIN_POLICY
    ON (OPTIN BOOLEAN);

-- ============================================================================
-- 2.7  SILVER governed Dynamic Table  (live pipeline; governance at query time)
--
--      Design principle: BRONZE carries RBAC access control and masking via tag
--      inheritance only. Aggregation and projection enforcement live on the SILVER
--      DT output. Purpose-specific row access lives on the contact activation view.
--
--      Tag-based masking stays on BRONZE (DT stores raw; masking applies at query
--      time on SILVER via propagated tags.
-- ============================================================================
USE ROLE AGOV_PIPELINE_SERVICE_ROLE;
CREATE OR REPLACE DYNAMIC TABLE AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS
    (
        ID FLOAT,
        FIRST_NAME VARCHAR,
        LAST_NAME VARCHAR,
        FULL_NAME VARCHAR,
        -- This override is defined with the DT so every CREATE OR REPLACE retains
        -- the correct classification instead of inheriting PII from EMAIL.
        EMAIL_DOMAIN VARCHAR WITH TAG (
            AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION = 'INTERNAL'
        ),
        EMAIL VARCHAR,
        PHONE_NUMBER VARCHAR,
        SSN VARCHAR,
        CREDITCARD VARCHAR,
        OPTIN BOOLEAN,
        STREET_ADDRESS VARCHAR,
        STATE VARCHAR,
        CITY VARCHAR,
        ZIP VARCHAR,
        COMPANY VARCHAR,
        JOB VARCHAR,
        ORDER_ID VARCHAR,
        ORDER_TS DATE,
        ORDER_CURRENCY VARCHAR,
        ORDER_AMOUNT FLOAT,
        ORDER_TAX FLOAT,
        ORDER_TOTAL FLOAT
    )
    TARGET_LAG    = '1 minute'
    WAREHOUSE     = AGOV_WH
    REFRESH_MODE  = FULL
AS
SELECT
    C.ID, C.FIRST_NAME, C.LAST_NAME,
    CONCAT(C.FIRST_NAME, ' ', C.LAST_NAME)            AS FULL_NAME,
    SPLIT_PART(C.EMAIL, '@', 2)                       AS EMAIL_DOMAIN,
    C.EMAIL, C.PHONE_NUMBER, C.SSN, C.CREDITCARD, C.OPTIN,
    C.STREET_ADDRESS, C.STATE, C.CITY, C.ZIP, C.COMPANY, C.JOB,
    O.ORDER_ID, O.ORDER_TS, O.ORDER_CURRENCY, O.ORDER_AMOUNT, O.ORDER_TAX, O.ORDER_TOTAL
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER C
LEFT JOIN AGENTIC_GOV_DB.BRONZE.CUSTOMER_ORDERS O ON C.ID = TRY_TO_NUMBER(O.CUSTOMER_ID);

-- CUSTOMER_ORDER_ANALYTICS stores ALL customers: no row access policy applied here.
-- Row-level consent enforcement is purpose-scoped to the contact activation view
-- only (CUSTOMER_CONTACT_ACTIVATION_V, section 2.10b). General analytics is
-- governed by masking, aggregation, and projection controls only.
USE ROLE AGOV_GOVERNOR;

-- SILVER schema default: SENSITIVE (fail-close).
-- Columns inherit SENSITIVE unless overridden; STRING/DATE policies apply by type.
-- This covers any column added to the pipeline later without being classified at source.
--
-- Because BRONZE.CUSTOMER and BRONZE.CUSTOMER_ORDERS are classified in sections 2.4/2.4b
-- before this DT is created, tag propagation via PROPAGATE = ON_DEPENDENCY_AND_DATA_MOVEMENT
-- flows from source columns to their corresponding DT columns at creation time.
-- No explicit column overrides are needed for propagated columns.
ALTER SCHEMA AGENTIC_GOV_DB.SILVER
    SET TAG AGENTIC_GOV_DB.GOVERNANCE.DATA_CLASSIFICATION = 'SENSITIVE';

-- Verify tag propagation: BRONZE source columns flow through to SILVER at DT creation time.
-- PII/RESTRICTED/SENSITIVE columns from BRONZE.CUSTOMER propagate directly.
-- ORDER_CURRENCY, ORDER_ID, ORDER_TS propagate as INTERNAL from BRONZE.CUSTOMER_ORDERS.
-- EMAIL_DOMAIN shows INTERNAL via the inline WITH TAG declaration in the DT definition.
-- Remaining untagged columns resolve to SENSITIVE (schema default). Numeric columns
-- (ID, ORDER_AMOUNT, ORDER_TAX, ORDER_TOTAL) still carry a tag value but stay in the
-- clear: masking is type-scoped and no STRING/DATE policy covers FLOAT.
SELECT COLUMN_NAME, TAG_VALUE AS classification_level
FROM TABLE(AGENTIC_GOV_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS','table'))
WHERE TAG_NAME = 'DATA_CLASSIFICATION'
ORDER BY COLUMN_NAME;

-- ============================================================================
-- 2.8  AGGREGATION POLICY (analyst must aggregate, cannot read raw orders)
--      Exemption keyed off the UNAGGREGATED_ACCESS database role (2.4d).
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
CREATE OR REPLACE AGGREGATION POLICY AGENTIC_GOV_DB.GOVERNANCE.AGG_POLICY
    AS () RETURNS AGGREGATION_CONSTRAINT ->
      CASE
        WHEN IS_ROLE_IN_SESSION('ACCOUNTADMIN')
          OR IS_DATABASE_ROLE_IN_SESSION('UNAGGREGATED_ACCESS') THEN NO_AGGREGATION_CONSTRAINT()
        ELSE AGGREGATION_CONSTRAINT(MIN_GROUP_SIZE => 100)
      END;

-- Apply to SILVER (the governed DT layer) — not to BRONZE (the DT input).
ALTER DYNAMIC TABLE AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS
    SET AGGREGATION POLICY AGENTIC_GOV_DB.GOVERNANCE.AGG_POLICY;

-- ============================================================================
-- 2.9  PROJECTION POLICY (ZIP cannot be projected by analyst)
--      IMPORTANT: apply the policy to the SILVER Dynamic Table output column,
--      NOT to BRONZE.CUSTOMER.ZIP.  Dynamic Table refreshes run as a background
--      task with no user session, so CURRENT_ROLE() and IS_ROLE_IN_SESSION both
--      resolve to NULL/FALSE on the base table check → ELSE → ALLOW => false →
--      error 391854. Policies on DT *output* columns are evaluated at query
--      time in a real user session, so both functions resolve correctly.
--      Exemption keyed off the UNRESTRICTED_PROJECTION_ACCESS database role
--      (2.4d), same reason as the aggregation policy above - a
--      role-hierarchy-aware capability check, not CURRENT_ROLE(), for
--      consistent exemption semantics whether the role is held as primary
--      or secondary.
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
CREATE OR REPLACE PROJECTION POLICY AGENTIC_GOV_DB.GOVERNANCE.PROJ_POLICY
    AS () RETURNS PROJECTION_CONSTRAINT ->
      CASE
        WHEN IS_ROLE_IN_SESSION('ACCOUNTADMIN')
          OR IS_DATABASE_ROLE_IN_SESSION('UNRESTRICTED_PROJECTION_ACCESS') THEN PROJECTION_CONSTRAINT(ALLOW => true)
        ELSE PROJECTION_CONSTRAINT(ALLOW => false)
      END;

-- Apply to SILVER (the governed DT layer) — not to BRONZE (the DT input).
ALTER DYNAMIC TABLE AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS
    MODIFY COLUMN ZIP SET PROJECTION POLICY AGENTIC_GOV_DB.GOVERNANCE.PROJ_POLICY;

-- ============================================================================
-- 2.10 VALIDATION  (governor full vs analyst governed)
-- ============================================================================
-- Publication checks first (pipeline identity, PASSED = TRUE): the left join keeps
-- all 1,000 customers (100 without orders) and every order once, and revenue matches BRONZE.
USE ROLE AGOV_PIPELINE_SERVICE_ROLE;
SELECT 'join_grain' AS check_name,
       COUNT(*) = 30100 AND COUNT(ORDER_ID) = 30000
       AND COUNT(DISTINCT ORDER_ID) = 30000
       AND COUNT(DISTINCT ID) = 1000 AS passed
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS;

SELECT 'revenue_reconciliation' AS check_name,
       ABS(source.REVENUE - target.REVENUE) < 0.000001 AS passed
FROM (SELECT SUM(ORDER_TOTAL) AS REVENUE FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER_ORDERS) source
CROSS JOIN (SELECT SUM(ORDER_TOTAL) AS REVENUE FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS) target;

-- Governor: full plaintext on BRONZE — privileged roles have direct access to the raw layer.
USE ROLE AGOV_GOVERNOR;
SELECT 'GOVERNOR' AS persona, FIRST_NAME, EMAIL, SSN, PHONE_NUMBER, JOB
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER LIMIT 5;

-- Engineer: masked on BRONZE — builds the pipeline but governance prevents raw PII exposure.
-- Masking applies because AGOV_ENGINEER is not in the plaintext exemption of the masking policy.
USE ROLE AGOV_ENGINEER;
SELECT 'ENGINEER on BRONZE' AS persona, FIRST_NAME, EMAIL, SSN, PHONE_NUMBER, JOB
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER LIMIT 5;

SELECT 'ENGINEER date mask' AS persona, BIRTHDATE
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER ORDER BY ID LIMIT 5;

-- RESTRICTED BIRTHDATE keeps the year only (January 1) for every row.
SELECT 'date_mask_year_only' AS check_name,
       COUNT(*) = 1000 AND COUNT(BIRTHDATE) = 1000
       AND COUNT_IF(MONTH(BIRTHDATE) <> 1 OR DAY(BIRTHDATE) <> 1) = 0 AS passed
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER;
USE ROLE AGOV_GOVERNOR;
SELECT 'GOVERNOR original date' AS persona, BIRTHDATE
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER ORDER BY ID LIMIT 5;
USE ROLE AGOV_ENGINEER;

-- Engineer on SILVER: same masked values — tags propagate from BRONZE to SILVER
-- via Dynamic Table column lineage, so governance travels with the data through the pipeline.
-- AGOV_ENGINEER is exempt from the aggregation policy so individual rows are accessible.
SELECT 'ENGINEER on SILVER' AS persona, FIRST_NAME, EMAIL, SSN, PHONE_NUMBER, JOB
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS LIMIT 5;
-- Same redaction as BRONZE → tag-based masking propagated; governance is not layer-specific.

-- Analyst: governed consumer layer — SILVER only. Two controls apply at query time:
--   1. Masking     — PII columns redacted at query time (propagated from BRONZE tags)
--   2. Aggregation — individual rows blocked; GROUP BY required (MIN_GROUP_SIZE policy)
-- Row-level consent filtering is NOT applied to analytics; all customers are present.
-- Contact activation is enforced on a separate secure view (section 2.10b).
USE ROLE AGOV_ANALYST;

-- Business aggregation: the analyst CAN do this.
-- ORDER_CURRENCY is explicitly tagged INTERNAL on SILVER — visible, not hashed.
-- ORDER_TOTAL is numeric — masking never applies; SUM is exact.
SELECT
    ORDER_CURRENCY,
    COUNT(ORDER_ID)      AS orders,
    SUM(ORDER_TOTAL)    AS total_revenue,
    COUNT(DISTINCT ID)  AS customers
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS
GROUP BY ORDER_CURRENCY
ORDER BY total_revenue DESC;

-- Masking proof for analyst: same column, two roles, completely different results.
-- GOVERNOR sees distinct non-null emails; deliberate email defects mean this is not customer count.
-- ANALYST sees every email masked to the identical '***PII-REDACTED***' string
--   → COUNT(DISTINCT EMAIL) = 1 regardless of how many customers exist.
-- This is a clean, aggregation-safe way to prove masking without violating any policy.
USE ROLE AGOV_GOVERNOR;
SELECT COUNT(DISTINCT EMAIL) AS distinct_emails FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS;
USE ROLE AGOV_ANALYST;
SELECT COUNT(DISTINCT EMAIL) AS distinct_emails FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS;
-- Governor: ~500+   Analyst: 1  →  masking confirmed.

SELECT 'analyst_email_mask' AS check_name,
       COUNT(*) = 30100 AND COUNT(DISTINCT EMAIL) = 1 AS passed
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS;


-- All-customers proof: analytics DT has no row access policy.
-- Governor and analyst return the same total row count; the governance difference
-- between roles is masking, aggregation, and projection — not row filtering.
USE ROLE AGOV_GOVERNOR;
SELECT COUNT(*) AS total_rows FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS;
USE ROLE AGOV_ANALYST;
SELECT COUNT(*) AS analyst_visible_rows FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS;
-- analyst_visible_rows = total_rows confirms all customers are present for the analyst.

-- Analyst projection policy on SILVER: ZIP cannot be projected.
-- SELECT ZIP FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS LIMIT 1;  -- expected: projection policy error
-- Governor CAN project ZIP directly from SILVER:
USE ROLE AGOV_GOVERNOR;
SELECT ZIP FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS LIMIT 1;   -- real ZIP value

-- ============================================================================
-- SNOWSIGHT: Full governance posture before publishing the GOLD data product
--
--   Governance > Tags & Policies > Dashboard
--     Tag coverage: DATA_CLASSIFICATION spans BRONZE and SILVER columns plus the
--     SILVER schema default. Masking Policy coverage reflects all classified and
--     schema-default columns across both layers.
--
--   Governance > Tags & Policies > Tagged Objects (filter: Columns, AGENTIC_GOV_DB)
--     BRONZE.CUSTOMER columns show their classified tier (EMAIL/CREDITCARD = PII,
--     ZIP = SENSITIVE, COMPANY/STATE = INTERNAL); the BRONZE demonstration defaults
--     from 2.5a are unset. STRING columns have MASK_BY_CLASSIFICATION_STRING active.
--     BIRTHDATE shows RESTRICTED with MASK_BY_CLASSIFICATION_DATE active.
--
--   Data > Databases > AGENTIC_GOV_DB > SILVER > CUSTOMER_ORDER_ANALYTICS > Columns tab
--     No Row Access Policy (analytics includes all customers; consent enforcement lives
--     on the contact activation view CUSTOMER_CONTACT_ACTIVATION_V, section 2.10b).
--     Aggregation Policy: AGG_POLICY on table.
--     Projection Policy: PROJ_POLICY on ZIP.
--     Masking Policy: MASK_BY_CLASSIFICATION_STRING / MASK_BY_CLASSIFICATION_DATE on classified columns (inherited from BRONZE tags).
--
--   This is the full governance foundation that SILVER and GOLD inherit at query
--   time. Nothing in Part 2 (agents) re-implements any of it.
-- ============================================================================

-- ============================================================================
-- 2.10b  CONTACT ACTIVATION VIEW + ACCESS GRANTS
--        CUSTOMER_CONTACT_ACTIVATION_V is the sole query surface for
--        AGOV_CONTACT_ACTIVATOR. It:
--          * Projects minimum-necessary contact PII: name, email, phone, opt-in.
--          * Omits SSN, CREDITCARD, STREET_ADDRESS, ZIP, and all order data.
--          * Carries CONSENT_ENFORCEMENT = 'CONTACT_OPT_IN_REQUIRED' -> tag-based
--            RAP requires OPTIN=TRUE AND an active CONTACT_ACTIVATION entitlement.
--          * Is SECURE: the view definition is not visible to non-owners.
--        AGOV_CONTACT_ACTIVATOR receives UNMASK_ACCESS + UNAGGREGATED_ACCESS so
--        it sees plaintext PII and individual rows for opted-in contacts.
--        UNRESTRICTED_PROJECTION_ACCESS is NOT granted (ZIP is absent from this view;
--        projection is not row-aware and conditional masking would leave rows present).
-- ============================================================================
USE ROLE AGOV_GOVERNOR;

CREATE OR REPLACE SECURE VIEW AGENTIC_GOV_DB.SILVER.CUSTOMER_CONTACT_ACTIVATION_V
    WITH TAG (AGENTIC_GOV_DB.GOVERNANCE.CONSENT_ENFORCEMENT = 'CONTACT_OPT_IN_REQUIRED')
    COMMENT = 'Minimum-necessary contact PII for CONTACT_ACTIVATION purpose only. Tag-based RAP requires OPTIN=TRUE and an active CONTACT_ACTIVATION entitlement. No order data or structural PII (SSN, CREDITCARD, STREET_ADDRESS, ZIP).'
AS
SELECT DISTINCT
    ID           AS CUSTOMER_ID,
    CONCAT(FIRST_NAME, ' ', LAST_NAME) AS FULL_NAME,
    EMAIL,
    PHONE_NUMBER,
    OPTIN
FROM AGENTIC_GOV_DB.BRONZE.CUSTOMER;

-- Capability roles: plaintext PII and individual rows for contact activator.
-- No UNRESTRICTED_PROJECTION_ACCESS - ZIP is absent from this view.
GRANT DATABASE ROLE AGENTIC_GOV_DB.UNMASK_ACCESS       TO ROLE AGOV_CONTACT_ACTIVATOR;
GRANT DATABASE ROLE AGENTIC_GOV_DB.UNAGGREGATED_ACCESS TO ROLE AGOV_CONTACT_ACTIVATOR;

-- Sole data-access grant: only this view, nothing else in SILVER/BRONZE/RAW.
GRANT SELECT ON VIEW AGENTIC_GOV_DB.SILVER.CUSTOMER_CONTACT_ACTIVATION_V
    TO ROLE AGOV_CONTACT_ACTIVATOR;

-- ============================================================================
-- 2.10c  CONTACT ACTIVATION VALIDATION
-- ============================================================================
-- 1. Analytics DT: both OPTIN states contribute (no RAP on analytics).
USE ROLE AGOV_GOVERNOR;
SELECT OPTIN, COUNT(DISTINCT ID) AS customer_count
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS
GROUP BY OPTIN
ORDER BY OPTIN;
-- Expect: rows for both TRUE and FALSE OPTIN -> analytics DT has no consent filter.

SELECT 'no_analytics_consent_filter' AS check_name, COUNT(*) = 0 AS passed
FROM TABLE(AGENTIC_GOV_DB.INFORMATION_SCHEMA.POLICY_REFERENCES(
    REF_ENTITY_NAME => 'AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS',
    REF_ENTITY_DOMAIN => 'TABLE'))
WHERE POLICY_KIND = 'ROW_ACCESS_POLICY';

-- 2. Contact activator: only opted-in rows; plaintext PII (UNMASK_ACCESS held).
USE ROLE AGOV_CONTACT_ACTIVATOR;
USE WAREHOUSE AGOV_WH;
USE SECONDARY ROLES NONE;

SELECT OPTIN, COUNT(*) AS row_count
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_CONTACT_ACTIVATION_V
GROUP BY OPTIN;
-- Expect: only OPTIN = TRUE present; no FALSE / NULL rows.

SELECT 'contact_grain_and_consent' AS check_name,
       COUNT(*) > 0 AND COUNT(*) = COUNT(DISTINCT CUSTOMER_ID)
       AND COUNT_IF(NOT COALESCE(OPTIN, FALSE)) = 0 AS passed
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_CONTACT_ACTIVATION_V;

SELECT CUSTOMER_ID, FULL_NAME, EMAIL, PHONE_NUMBER, OPTIN
FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_CONTACT_ACTIVATION_V
LIMIT 5;
-- Expect: plaintext name/email/phone (UNMASK_ACCESS bypasses masking); OPTIN = TRUE.

-- 3. Disable entitlement -> zero rows; re-enable -> rows return.
--    Toggle as governor (contact activator has no UPDATE on governance tables).
USE ROLE AGOV_GOVERNOR;
UPDATE AGENTIC_GOV_DB.GOVERNANCE.POLICY_ENTITLEMENTS
    SET IS_ENABLED = FALSE
    WHERE ENTITLEMENT_NAME = 'CONTACT_ACTIVATION'
      AND PRINCIPAL_NAME   = 'AGOV_CONTACT_ACTIVATOR';

USE ROLE AGOV_CONTACT_ACTIVATOR;
SELECT COUNT(*) AS should_be_zero FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_CONTACT_ACTIVATION_V;
-- Expect: 0 — entitlement disabled; OPTIN=TRUE alone is not sufficient.

USE ROLE AGOV_GOVERNOR;
UPDATE AGENTIC_GOV_DB.GOVERNANCE.POLICY_ENTITLEMENTS
    SET IS_ENABLED = TRUE
    WHERE ENTITLEMENT_NAME = 'CONTACT_ACTIVATION'
      AND PRINCIPAL_NAME   = 'AGOV_CONTACT_ACTIVATOR';

USE ROLE AGOV_CONTACT_ACTIVATOR;
SELECT COUNT(*) AS should_be_nonzero FROM AGENTIC_GOV_DB.SILVER.CUSTOMER_CONTACT_ACTIVATION_V;
-- Expect: > 0 — entitlement restored; opted-in rows visible again.

-- Return to governor for subsequent sections.
USE ROLE AGOV_GOVERNOR;

-- ============================================================================
-- 2.11 PUBLISH THE GOVERNED GOLD SEMANTIC VIEW (the data product for AI)
--      GOLD is still data governance: the semantic view is built over governed
--      SILVER, so masking, aggregation, and projection policies are inherited
--      at query time — nothing is re-implemented.
--      Built by AGOV_PIPELINE_SERVICE_ROLE, the CI/CD identity that owns every
--      deployable medallion object. Human engineer and governor roles can inspect
--      the product but do not own or publish it.
-- ============================================================================
USE ROLE AGOV_PIPELINE_SERVICE_ROLE;
USE SCHEMA GOLD;
CREATE OR REPLACE SEMANTIC VIEW AGENTIC_GOV_DB.GOLD.CUSTOMER_ANALYTICS_SV
  TABLES (
    analytics AS AGENTIC_GOV_DB.SILVER.CUSTOMER_ORDER_ANALYTICS
      WITH SYNONYMS ('customer orders','sales data','analytics')
      COMMENT = 'Governed customer order analytics for all customers; masking/aggregation/projection inherited from BRONZE/SILVER. Contact activation uses a separate secure view (CUSTOMER_CONTACT_ACTIVATION_V).'
  )
  FACTS (
    analytics.order_amount_fact AS ORDER_AMOUNT,
    analytics.order_tax_fact    AS ORDER_TAX,
    analytics.order_total_fact  AS ORDER_TOTAL
  )
  DIMENSIONS (
    analytics.customer_id   AS ID,
    analytics.full_name     AS FULL_NAME       WITH SYNONYMS = ('name','customer name'),
    analytics.email         AS EMAIL           WITH SYNONYMS = ('email','contact email'),
    analytics.phone_number  AS PHONE_NUMBER    WITH SYNONYMS = ('phone'),
    analytics.email_domain  AS EMAIL_DOMAIN,
    analytics.company_name  AS COMPANY         WITH SYNONYMS = ('company','employer'),
    analytics.job_title     AS JOB,
    analytics.location_state AS STATE          WITH SYNONYMS = ('state','region'),
    analytics.location_city AS CITY,
    analytics.order_id      AS ORDER_ID,
    analytics.order_date    AS ORDER_TS        WITH SYNONYMS = ('order date','date'),
    analytics.currency      AS ORDER_CURRENCY
  )
  METRICS (
    analytics.total_revenue       AS SUM(analytics.order_total_fact) WITH SYNONYMS = ('revenue','total sales'),
    analytics.total_orders        AS COUNT(analytics.order_id)       WITH SYNONYMS = ('order count'),
    analytics.average_order_value AS AVG(analytics.order_total_fact) WITH SYNONYMS = ('AOV'),
    analytics.customer_count      AS COUNT(DISTINCT analytics.customer_id)
  )
  COMMENT = 'GOLD semantic view for Cortex Analyst / agents';

-- Reassert consumer access at publication time. This also repairs grants after a
-- lab-time GOLD ownership transfer, which can revoke existing schema grants.
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.GOLD TO ROLE AGOV_GOVERNOR;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.GOLD TO ROLE AGOV_ENGINEER;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.GOLD TO ROLE AGOV_ANALYST;
GRANT USAGE ON SCHEMA AGENTIC_GOV_DB.GOLD TO ROLE AGOV_AUDITOR;

GRANT SELECT ON SEMANTIC VIEW AGENTIC_GOV_DB.GOLD.CUSTOMER_ANALYTICS_SV TO ROLE AGOV_GOVERNOR;
GRANT SELECT ON SEMANTIC VIEW AGENTIC_GOV_DB.GOLD.CUSTOMER_ANALYTICS_SV TO ROLE AGOV_ENGINEER;
GRANT SELECT ON SEMANTIC VIEW AGENTIC_GOV_DB.GOLD.CUSTOMER_ANALYTICS_SV TO ROLE AGOV_ANALYST;
GRANT SELECT ON SEMANTIC VIEW AGENTIC_GOV_DB.GOLD.CUSTOMER_ANALYTICS_SV TO ROLE AGOV_AUDITOR;

SHOW SEMANTIC VIEWS LIKE 'CUSTOMER_ANALYTICS_SV';

-- Note which sensitive columns the view deliberately does NOT expose (SSN, CREDITCARD,
-- STREET_ADDRESS): even a fully privileged caller cannot reach them through this surface.

-- Lesson-boundary check: the analyst reads the published GOLD metrics.
USE ROLE AGOV_ANALYST;
SELECT 'gold_metrics' AS check_name,
       CUSTOMER_COUNT = 1000 AND TOTAL_ORDERS = 30000
       AND ABS(TOTAL_REVENUE - 743292.7625) < 0.000001 AS passed
FROM SEMANTIC_VIEW(AGENTIC_GOV_DB.GOLD.CUSTOMER_ANALYTICS_SV
    METRICS analytics.customer_count, analytics.total_orders, analytics.total_revenue);
-- Part 2 (02-02) proves this "only what is in the view" boundary against the agent.