/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale (Teardown)
Purpose:      Remove lab objects once. Repeated execution is not guaranteed when the database is absent.
              The guarded session-policy cleanup tolerates prior cleanup in 02-04.6
              and refuses to remove an unrelated policy. Run manually in a human worksheet.
Order:        1. Capture CURRENT_USER; detach only the demo user-level session policy.
                 This redesign never changes DEFAULT_ROLE/DEFAULT_WAREHOUSE (see
                 02-04-Restricted-Session-Scope.sql), so there is nothing to restore there.
              2. Drop session policies, then RSS (policies reference the scope; drop
                 policies first).
              2b. AI cost governance (05-01..05-04): revoke APPLICATION SNOWFLAKE grants
                 and UNSET the AI_COST_CENTER user tag before the database drop.
              3. Drop database.
              4. Reset DEFAULT_SECONDARY_ROLES and the PUBLIC model grants to Snowflake defaults.
              5. Drop AGOV_COST_APP_ROLE (USERADMIN), the AGOV roles (SECURITYADMIN),
                 then revoke the SECURITYADMIN self-grants from 00-Setup.sql 0.7.
              6. Drop warehouse last (SYSADMIN); earlier steps run on it.
              Roles: SECURITYADMIN, SYSADMIN, and USERADMIN drop what they own or
              inherit. ACCOUNTADMIN runs only the labeled block in section 4.

              Cleanup sets documented defaults; it does not capture and restore the
              account's or operator's state from before the lab. Left in place:
                - CORTEX_ENABLED_CROSS_REGION stays 'AWS_GLOBAL' (set in 00-Setup).
                - CORTEX_MODELS_ALLOWLIST stays 'None' (set in 02-01; see section 4).
                - The model catalog refresh, if it was run, is not reversed.
              DEFAULT_SECONDARY_ROLES is set to ('ALL') and the PUBLIC all-model grants are
              re-granted, whatever they were before the lab. The data movement tag, rules,
              and policy (03-01) are removed with the database.
              To return to your earlier values, use the optional section 4b with the
              values captured in 00-Setup section 0.0.

              IMPORTANT: This lab only proceeds when the operator had NO pre-existing user-level
              session policy (verified by preflight P.6). Detaching the demo policy restores
              account-level behavior. If another policy is attached, cleanup raises an error
              and leaves it untouched. Stop execution on that error before dropping lab objects.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
***************************************************************************************************/

-- SECURITYADMIN owns the 02-04 session policy and RSS, and holds MANAGE GRANTS
-- plus the APPLY SESSION POLICY / APPLY TAG self-grants from 00-Setup.sql 0.7.
USE ROLE SECURITYADMIN;
USE WAREHOUSE AGOV_WH;

-- ============================================================================
-- 1.  CAPTURE OPERATOR, UNSET SESSION POLICY (02-04)
--     UNSET must precede DROP SESSION POLICY (policy in use would error).
--     UNSET restores account-level session policy behavior for this user.
--     Run manually as SECURITYADMIN in a human worksheet, not through the agent.
--     Prior 02-04.6 cleanup is a no-op. An unrelated policy is left untouched.
--     Stop execution on any error before continuing with the DROP statements.
-- ============================================================================
SET my_user = CURRENT_USER();

-- Same attachment guard as 02-04.6. Do not swallow metadata or permission errors.
EXECUTE IMMEDIATE $$
DECLARE
    u STRING;
    total_count INTEGER;
    exact_count INTEGER;
    unexpected_policy EXCEPTION (-20002, 'Unexpected user session policy found; it was left untouched.');
BEGIN
    u := CURRENT_USER();
    SELECT COUNT(*),
           COUNT_IF(POLICY_DB = 'AGENTIC_GOV_DB'
                    AND POLICY_SCHEMA = 'GOVERNANCE'
                    AND POLICY_NAME = 'AGENT_DEMO_SESSION_POLICY')
    INTO :total_count, :exact_count
    FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME => CURRENT_USER(), REF_ENTITY_DOMAIN => 'USER'))
    WHERE POLICY_KIND = 'SESSION_POLICY';
    IF (total_count = 0) THEN
        RETURN 'No user session policy attached. Nothing to detach.';
    ELSEIF (total_count = 1 AND exact_count = 1) THEN
        ALTER USER IDENTIFIER(:u) UNSET SESSION POLICY;
        RETURN 'Detached AGENTIC_GOV_DB.GOVERNANCE.AGENT_DEMO_SESSION_POLICY.';
    ELSE
        RAISE unexpected_policy;
    END IF;
END;
$$;

-- ============================================================================
-- 2.  RSS + SESSION POLICIES (02-04)
--     DROP ORDER: policies before scope (the policies reference the scope;
--     drop the referencing objects first).
-- ============================================================================
DROP SESSION POLICY            IF EXISTS AGENTIC_GOV_DB.GOVERNANCE.AGENT_DEMO_SESSION_POLICY;
DROP SESSION POLICY            IF EXISTS AGENTIC_GOV_DB.GOVERNANCE.AGENT_NOOP_SESSION_POLICY;
DROP RESTRICTED SESSION SCOPE  IF EXISTS AGENTIC_GOV_DB.GOVERNANCE.AGENT_ANALYST_SCOPE;

-- ============================================================================
-- 2b. AI COST GOVERNANCE (05-01..05-04)
--     Explicit cleanup before the database drop for objects that reach
--     outside the database (APPLICATION SNOWFLAKE grants) or attach to the
--     operator directly (the AI_COST_CENTER user tag). Everything else in
--     COST_MANAGEMENT (budget, quota, procedures, tag definition, log table)
--     is removed automatically when the database is dropped in step 3 - kept
--     in its own schema for exactly this reason.
-- ============================================================================
-- Exception-safe REVOKE: swallows "schema/database does not exist" if 05-01
-- never ran (COST_MANAGEMENT is only created there, not in 00-Setup.sql).
EXECUTE IMMEDIATE $$
BEGIN
  REVOKE USAGE ON SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT FROM APPLICATION SNOWFLAKE;
EXCEPTION WHEN OTHER THEN
  NULL;
END;
$$;
EXECUTE IMMEDIATE $$
BEGIN
  REVOKE USAGE ON DATABASE AGENTIC_GOV_DB FROM APPLICATION SNOWFLAKE;
EXCEPTION WHEN OTHER THEN
  NULL;
END;
$$;

-- Exception-safe UNSET: swallows "tag not applied" error if 05-01 never ran.
EXECUTE IMMEDIATE $$
DECLARE
  u STRING;
BEGIN
  u := CURRENT_USER();
  ALTER USER IDENTIFIER(:u) UNSET TAG AGENTIC_GOV_DB.COST_MANAGEMENT.AI_COST_CENTER;
EXCEPTION WHEN OTHER THEN
  NULL;
END;
$$;

-- ============================================================================
-- 3.  DATABASE (removes all schemas, tables, semantic views, policies, tags,
--     classifiers, Cortex Agents, agent registry, and COST_MANAGEMENT's
--     budgets, quota,
--     procedures, log table, and the 05-06 AI Cost Control app service)
--     SYSADMIN drops it through the inherited owner role AGOV_ENGINEER
--     (granted to SYSADMIN in 00-Setup.sql 0.1).
-- ============================================================================
USE ROLE SYSADMIN;
DROP DATABASE IF EXISTS AGENTIC_GOV_DB;

-- ============================================================================
-- 4.  RESET OPERATOR DEFAULT_SECONDARY_ROLES (set to () in 00-Setup.sql)
--     Sets ('ALL'), the Snowflake default; any earlier custom value is not restored.
--     Re-grant the account-wide all-model bootstrap removed by 02-01. The legacy
--     CORTEX_MODELS_ALLOWLIST remains None because Snowflake no longer permits
--     changing it back to All during the 2026 allowlist retirement.
-- ============================================================================
USE ROLE SECURITYADMIN;
ALTER USER IDENTIFIER($my_user) SET DEFAULT_SECONDARY_ROLES = ('ALL');

-- ----------------------------------------------------------------------------
-- ACCOUNTADMIN required: SNOWFLAKE.LOCAL bootstrap procedure, SNOWFLAKE
-- application-role grant to PUBLIC, and the optional 4b account parameters
-- (https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql-privileges-and-access).
-- ----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
CALL SNOWFLAKE.LOCAL.GRANT_TO_PUBLIC_APPLICATION_ROLE(
    'APP_ROLE',
    'CORTEX-MODEL-ROLE-ALL'
);

-- Re-grant the customer-managed PUBLIC grant removed by 02-01 as a separate path.
GRANT APPLICATION ROLE SNOWFLAKE."CORTEX-MODEL-ROLE-ALL" TO ROLE PUBLIC;

-- ============================================================================
-- 4b. RESTORE YOUR CAPTURED SETTINGS (optional, commented out by default)
--     Uses the values you recorded in 00-Setup section 0.0 CAPTURE PRIOR SETTINGS.
--     Uncomment a statement only if you captured a value and it differs from
--     what section 4 set. Replace each <captured_value> before running.
--     Skip this section if you did not capture values.
-- ============================================================================
-- C.1  Cross-region inference. Use UNSET if the captured level was empty (default).
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = '<captured_value>';
-- ALTER ACCOUNT UNSET CORTEX_ENABLED_CROSS_REGION;

-- C.2  Legacy model allowlist. Snowflake no longer accepts All. Restore a captured
--      model list only, or UNSET if the captured level was empty (default).
-- ALTER ACCOUNT SET CORTEX_MODELS_ALLOWLIST = '<captured_value>';
-- ALTER ACCOUNT UNSET CORTEX_MODELS_ALLOWLIST;

-- C.3  DEFAULT_SECONDARY_ROLES. Section 4 set ('ALL'). Use () if that was captured.
-- ALTER USER IDENTIFIER($my_user) SET DEFAULT_SECONDARY_ROLES = ();

-- C.4  Customer-managed PUBLIC grant. Section 4 granted it. Revoke if C.4 was empty.
-- REVOKE APPLICATION ROLE SNOWFLAKE."CORTEX-MODEL-ROLE-ALL" FROM ROLE PUBLIC;

-- C.5  Snowflake-managed bootstrap. Section 4 restored it. Revoke if C.5 was empty.
-- CALL SNOWFLAKE.LOCAL.REVOKE_FROM_PUBLIC_APPLICATION_ROLE(
--     'APP_ROLE',
--     'CORTEX-MODEL-ROLE-ALL'
-- );
-- End of ACCOUNTADMIN block.

-- ============================================================================
-- 5.  ROLES (SECURITYADMIN scope; order: child before parent)
--     Database roles (UNMASK_ACCESS, UNAGGREGATED_ACCESS,
--     UNRESTRICTED_PROJECTION_ACCESS) are dropped automatically with the
--     database in step 3 - no separate DROP DATABASE ROLE needed.
--     ALL_ROWS_ACCESS no longer exists (analytics DT has no row access policy).
--     AGENTIC_UNMASK_ACCESS, AGOV_PIPELINE_SERVICE_ROLE, and
--     AGOV_CONTACT_ACTIVATOR are account-level roles dropped below.
-- ============================================================================
-- 05-06 (optional app). Drop first, and as USERADMIN (its creator/owner in
-- 05-06): the app role holds budget/quota VIEWER grants, which would otherwise
-- block dropping the governor below.
USE ROLE USERADMIN;
DROP ROLE IF EXISTS AGOV_COST_APP_ROLE;

USE ROLE SECURITYADMIN;
DROP ROLE IF EXISTS AGENTIC_UNMASK_ACCESS;
DROP ROLE IF EXISTS AGOV_ENGINEER;
DROP ROLE IF EXISTS AGOV_GOVERNOR;
DROP ROLE IF EXISTS AGOV_ANALYST;
DROP ROLE IF EXISTS AGOV_AUDITOR;
DROP ROLE IF EXISTS AGOV_CONTACT_ACTIVATOR;
DROP ROLE IF EXISTS AGOV_PIPELINE_SERVICE_ROLE;

-- 5b. Revoke the SECURITYADMIN self-grants from 00-Setup.sql 0.7. Its USAGE and
--     CREATE grants on AGOV_WH, AGENTIC_GOV_DB, and GOVERNANCE go with those objects.
REVOKE APPLY SESSION POLICY ON ACCOUNT FROM ROLE SECURITYADMIN;
REVOKE DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER FROM ROLE SECURITYADMIN;

-- ACCOUNTADMIN required: the APPLY TAG self-grant is recorded with ACCOUNTADMIN
-- as grantor, so a SECURITYADMIN revoke affects 0 objects (rehearsal 2026-11-02)
USE ROLE ACCOUNTADMIN;
REVOKE APPLY TAG ON ACCOUNT FROM ROLE SECURITYADMIN;

-- ============================================================================
-- 6.  WAREHOUSE (last: the CALLs and EXECUTE IMMEDIATE blocks above run on it)
-- ============================================================================
USE ROLE SYSADMIN;
DROP WAREHOUSE IF EXISTS AGOV_WH;

