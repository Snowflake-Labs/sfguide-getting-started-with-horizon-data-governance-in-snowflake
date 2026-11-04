/***************************************************************************************************
| H | O | R | I | Z | O | N |   | L | A | B | S |

Demo:         Agentic Governance at Scale
Part:         PART 5 - AI Cost Governance
Section:      05-04 - Notifications, Custom Actions & Enforcement
Persona:      AGOV_GOVERNOR (cost administrator, owner of the owner-rights procedures)
Story beat:   Run after 05-03. A budget threshold is only useful if something HAPPENS when it
              fires. This section registers the notification email, then a safe audit-log
              custom action and an email alert on each budget, then demonstrates - WITHOUT
              REGISTERING IT LIVE - the one enforcement action that is actually native to this
              lab: revoking the analyst's USAGE grant on CUSTOMER_INSIGHTS_AGENT (the exact
              grant issued in 02-01-Capability-Governance.sql), which only makes sense on the
              AGENT budget.
              The QUOTA side adds a daily email notification (the one threshold that fires
              within minutes) and shows the built-in AI-access block, which stays OFF.
              Timing: budget thresholds fire only after the budget refreshes (up to ~6.5h),
              so budget emails / log rows appear hours later; the quota email arrives within
              minutes. Check results in 05-05.
Copyright(c): 2026 Snowflake Inc. Licensed under the Apache License, Version 2.0.
****************************************************************************************************/

-- ⚠️  SAFETY NOTE: this is the presenter's real account. Block Enforcement
--     (SET_BLOCK_ENFORCEMENT_ENABLED) and the agent-access revoke/restore
--     custom action are both left COMMENTED. Uncomment only with an
--     instructor's explicit approval, and only on a disposable account.

USE ROLE AGOV_GOVERNOR;
USE WAREHOUSE AGOV_WH;
USE SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT;

-- ============================================================================
-- 5.12 NOTIFICATION EMAIL (one-time, before registering any threshold)
--      Budget and quota emails go only to VERIFIED addresses; an unverified
--      address makes SET_EMAIL_NOTIFICATIONS / SET_ADMIN_EMAILS fail, and
--      quota user notifications for an unverified user are logged to the
--      event table instead of sent.
--      Step 1 (Snowsight, once): avatar (bottom left) -> Settings -> My profile
--              -> Email: enter your address, then click the link in the
--              verification email Snowflake sends. Quota per-user emails go to
--              this profile address.
--      Step 2 (here): put the SAME verified address below. It is used for the
--              budget alerts (5.12b) and the quota admin summary (5.14).
-- ============================================================================
SET NOTIFY_EMAIL = '<your_email_address>';   -- <-- PLEASE EDIT THIS LINE

-- Check the address on your user (should match NOTIFY_EMAIL). Verification
-- status itself is shown in Snowsight -> My profile.
-- DESCRIBE USER returns lowercase column names, so they must be double-quoted.
-- The pipe operator (->>) keeps this one statement, so it also works when run
-- alone (RESULT_SCAN(LAST_QUERY_ID()) breaks if another statement ran between).
USE ROLE SECURITYADMIN;
SET my_user = CURRENT_USER();
DESCRIBE USER IDENTIFIER($my_user)
->> SELECT "property", "value" FROM $1 WHERE "property" = 'EMAIL';

USE ROLE AGOV_GOVERNOR;
USE SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT;

-- ============================================================================
-- 5.12a CUSTOM ACTION PROCEDURE: idempotent audit-log write
--      Intentionally non-destructive so it is always safe to register and
--      trigger. EXECUTE AS OWNER, 30-minute ceiling, scalar arguments only.
-- ============================================================================
CREATE OR REPLACE PROCEDURE AGENTIC_GOV_DB.COST_MANAGEMENT.LOG_BUDGET_THRESHOLD(
    EVENT_ID     VARCHAR,
    CONTROL_NAME VARCHAR,
    ACTION_NAME  VARCHAR,
    SCOPE_NAME   VARCHAR,
    THRESHOLD    NUMBER,
    DETAILS      VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    MERGE INTO AGENTIC_GOV_DB.COST_MANAGEMENT.AI_BUDGET_ACTION_LOG AS target
    USING (
        SELECT :EVENT_ID || '_' || TO_VARCHAR(CURRENT_DATE()) AS EVENT_ID,
               :CONTROL_NAME AS CONTROL_NAME,
               :ACTION_NAME  AS ACTION_NAME,
               :SCOPE_NAME   AS SCOPE_NAME,
               :THRESHOLD    AS THRESHOLD,
               TRY_PARSE_JSON(:DETAILS) AS DETAILS
    ) AS source
    ON target.EVENT_ID = source.EVENT_ID
    WHEN NOT MATCHED THEN INSERT (
        EVENT_ID, CONTROL_NAME, ACTION_NAME, SCOPE_NAME, THRESHOLD, DETAILS
    ) VALUES (
        source.EVENT_ID, source.CONTROL_NAME, source.ACTION_NAME,
        source.SCOPE_NAME, source.THRESHOLD, source.DETAILS
    );
    RETURN 'Recorded action event ' || :EVENT_ID;
END;
$$;

GRANT USAGE ON PROCEDURE AGENTIC_GOV_DB.COST_MANAGEMENT.LOG_BUDGET_THRESHOLD(
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, NUMBER, VARCHAR
) TO APPLICATION SNOWFLAKE;

-- ============================================================================
-- 5.12b REGISTER A 1%-ACTUAL CUSTOM ACTION + EMAIL ALERT PER BUDGET
--      Both budgets have a 1-credit limit (05-02), so 1% = 0.01 credit: Part 2
--      / Part 3 agent calls and 05-03 are well past it. Same procedure,
--      different arguments, so the action log shows which service's budget
--      fired. ACTUAL actions run at most once per month; run once, and remove
--      the prior action first if re-running.
--      DELAY: the action and the email fire only after the budget refreshes
--      (up to ~6.5h, 1h on the low-latency tier), not when the spend happens.
--      Budget emails are forecast-based daily alerts: they are sent when the
--      PROJECTED month-end spend exceeds the notification threshold.
-- ============================================================================
CALL AGOV_AGENT_BUDGET!ADD_CUSTOM_ACTION(
    SYSTEM$REFERENCE(
        'PROCEDURE',
        'AGENTIC_GOV_DB.COST_MANAGEMENT.LOG_BUDGET_THRESHOLD(VARCHAR, VARCHAR, VARCHAR, VARCHAR, NUMBER, VARCHAR)',
        'SESSION',
        'USAGE'
    ),
    ARRAY_CONSTRUCT(
        'AGOV_AGENT_BUDGET_1', 'AGOV_AGENT_BUDGET', 'WARN',
        'BUSINESS_ANALYTICS', 1, '{"service":"CORTEX AGENT"}'
    ),
    'ACTUAL',
    1
);

CALL AGOV_AI_FUNCTION_BUDGET!ADD_CUSTOM_ACTION(
    SYSTEM$REFERENCE(
        'PROCEDURE',
        'AGENTIC_GOV_DB.COST_MANAGEMENT.LOG_BUDGET_THRESHOLD(VARCHAR, VARCHAR, VARCHAR, VARCHAR, NUMBER, VARCHAR)',
        'SESSION',
        'USAGE'
    ),
    ARRAY_CONSTRUCT(
        'AGOV_AI_FUNCTION_BUDGET_1', 'AGOV_AI_FUNCTION_BUDGET', 'WARN',
        'BUSINESS_ANALYTICS', 1, '{"service":"AI FUNCTION"}'
    ),
    'ACTUAL',
    1
);

CALL AGOV_AGENT_BUDGET!CONFIRM_CUSTOM_ACTIONS_ACCESS();
CALL AGOV_AI_FUNCTION_BUDGET!CONFIRM_CUSTOM_ACTIONS_ACCESS();
CALL AGOV_AGENT_BUDGET!GET_CUSTOM_ACTIONS();
CALL AGOV_AI_FUNCTION_BUDGET!GET_CUSTOM_ACTIONS();

-- Email alert at 1% of the limit (projected), to the address from 5.12.
CALL AGOV_AGENT_BUDGET!SET_EMAIL_NOTIFICATIONS($NOTIFY_EMAIL);
CALL AGOV_AGENT_BUDGET!SET_NOTIFICATION_THRESHOLD(1);
CALL AGOV_AI_FUNCTION_BUDGET!SET_EMAIL_NOTIFICATIONS($NOTIFY_EMAIL);
CALL AGOV_AI_FUNCTION_BUDGET!SET_NOTIFICATION_THRESHOLD(1);

-- Dry run: call the procedure directly to see the row each budget's action
-- would write, without waiting for the budget refresh. Remove these rows before
-- a real demo if you want the log to contain only budget-fired events.
CALL AGENTIC_GOV_DB.COST_MANAGEMENT.LOG_BUDGET_THRESHOLD(
    'DRYRUN_AGOV_AGENT_BUDGET_1', 'AGOV_AGENT_BUDGET', 'WARN',
    'BUSINESS_ANALYTICS', 1, '{"service":"CORTEX AGENT","dry_run":true}');
CALL AGENTIC_GOV_DB.COST_MANAGEMENT.LOG_BUDGET_THRESHOLD(
    'DRYRUN_AGOV_AI_FUNCTION_BUDGET_1', 'AGOV_AI_FUNCTION_BUDGET', 'WARN',
    'BUSINESS_ANALYTICS', 1, '{"service":"AI FUNCTION","dry_run":true}');
-- The two dry-run rows are checked in 5.15.

-- ============================================================================
-- 5.13 LAB-NATIVE ENFORCEMENT PATTERN (inspect only - registration commented)
--      A custom action can change external state, not just log. The most
--      relevant lever THIS lab already has is the analyst's USAGE grant on
--      CUSTOMER_INSIGHTS_AGENT, issued in 02-01-Capability-Governance.sql:
--        GRANT USAGE ON AGENT AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT
--            TO ROLE AGOV_ANALYST;
--      Revoking it at 100% actual spend removes the analyst's only path to
--      the agent; a monthly cycle-start action restores it at the next cycle.
--      It belongs on AGOV_AGENT_BUDGET: AI Function spend should not cut off
--      agent access.
--      AGOV_GOVERNOR owns CUSTOMER_INSIGHTS_AGENT, so it creates these
--      owner-rights procedures itself. An agent owner can grant and revoke
--      USAGE on its own agent, so neither the procedures nor the governor
--      need MANAGE GRANTS, and no ACCOUNTADMIN-owned object remains.
-- ============================================================================
USE ROLE AGOV_GOVERNOR;
USE SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT;

CREATE OR REPLACE PROCEDURE AGENTIC_GOV_DB.COST_MANAGEMENT.REVOKE_AGENT_ACCESS(EVENT_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    EXECUTE IMMEDIATE
        'REVOKE USAGE ON AGENT AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT FROM ROLE AGOV_ANALYST';
    CALL AGENTIC_GOV_DB.COST_MANAGEMENT.LOG_BUDGET_THRESHOLD(
        :EVENT_ID, 'AGOV_AGENT_BUDGET', 'REVOKE_AGENT_ACCESS', 'BUSINESS_ANALYTICS', 100,
        '{"agent":"CUSTOMER_INSIGHTS_AGENT","role":"AGOV_ANALYST"}'
    );
    RETURN 'AGOV_ANALYST USAGE on CUSTOMER_INSIGHTS_AGENT revoked';
END;
$$;

CREATE OR REPLACE PROCEDURE AGENTIC_GOV_DB.COST_MANAGEMENT.RESTORE_AGENT_ACCESS(EVENT_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    EXECUTE IMMEDIATE
        'GRANT USAGE ON AGENT AGENTIC_GOV_DB.AGENTS.CUSTOMER_INSIGHTS_AGENT TO ROLE AGOV_ANALYST';
    CALL AGENTIC_GOV_DB.COST_MANAGEMENT.LOG_BUDGET_THRESHOLD(
        :EVENT_ID, 'AGOV_AGENT_BUDGET', 'RESTORE_AGENT_ACCESS', 'BUSINESS_ANALYTICS', 0,
        '{"agent":"CUSTOMER_INSIGHTS_AGENT","role":"AGOV_ANALYST"}'
    );
    RETURN 'AGOV_ANALYST USAGE on CUSTOMER_INSIGHTS_AGENT restored';
END;
$$;

GRANT USAGE ON PROCEDURE AGENTIC_GOV_DB.COST_MANAGEMENT.REVOKE_AGENT_ACCESS(VARCHAR)  TO APPLICATION SNOWFLAKE;
GRANT USAGE ON PROCEDURE AGENTIC_GOV_DB.COST_MANAGEMENT.RESTORE_AGENT_ACCESS(VARCHAR) TO APPLICATION SNOWFLAKE;

USE ROLE AGOV_GOVERNOR;
USE SCHEMA AGENTIC_GOV_DB.COST_MANAGEMENT;

-- Registration deliberately commented: this would remove AGOV_ANALYST's only
-- path to the agent for the rest of this lab session. Uncomment only with
-- instructor approval, immediately followed by the matching cycle-start
-- restore action below.
-- CALL AGOV_AGENT_BUDGET!ADD_CUSTOM_ACTION(
--     SYSTEM$REFERENCE(
--         'PROCEDURE',
--         'AGENTIC_GOV_DB.COST_MANAGEMENT.REVOKE_AGENT_ACCESS(VARCHAR)',
--         'SESSION',
--         'USAGE'
--     ),
--     ARRAY_CONSTRUCT('AGOV_AGENT_BUDGET_100'),
--     'ACTUAL',
--     100
-- );
-- CALL AGOV_AGENT_BUDGET!SET_CYCLE_START_ACTION(
--     SYSTEM$REFERENCE(
--         'PROCEDURE',
--         'AGENTIC_GOV_DB.COST_MANAGEMENT.RESTORE_AGENT_ACCESS(VARCHAR)',
--         'SESSION',
--         'USAGE'
--     ),
--     ARRAY_CONSTRUCT('AGOV_AGENT_BUDGET_MONTH_START')
-- );

-- ============================================================================
-- 5.14 QUOTA DAILY EMAIL AND THE BUILT-IN BLOCK (block left disabled)
--      10% of the 1-credit DAILY limit = 0.1 credit; 05-03's bulk
--      AI_COMPLETE passes it within its first rows. Quotas are evaluated
--      within minutes, so this is the email you can watch arrive in-session
--      (allow ~5-10 min for new settings to propagate).
--      ACTUAL, not PROJECTED: projections are not calculated during roughly
--      the first 12 hours of a daily cycle (cycle starts 00:00 UTC), so a
--      PROJECTED daily threshold would stay silent for most of the day.
--      ACTUAL thresholds notify at most once per cycle (here: once per day).
-- ============================================================================
-- Per-user email to the tagged user's verified profile address (5.12 Step 1).
-- Run once; REMOVE_NOTIFICATION_THRESHOLD(10, 'ACTUAL') before rerunning.
CALL AGOV_AI_QUOTA!ADD_NOTIFICATION_THRESHOLD(10, 'ACTUAL', TRUE, 'DAILY');

-- Admin summary of all users who crossed a threshold, to NOTIFY_EMAIL (5.12).
CALL AGOV_AI_QUOTA!SET_ADMIN_EMAILS($NOTIFY_EMAIL);

-- Live AI-access blocking. Leave commented on this shared/production account.
-- CALL AGOV_AI_QUOTA!SET_BLOCK_ENFORCEMENT_ENABLED(TRUE, TRUE);

CALL AGOV_AI_QUOTA!GET_CONFIG();
CALL AGOV_AI_QUOTA!GET_NOTIFICATION_THRESHOLDS();

-- Quota custom actions receive a JSON-encoded user ID array as their first
-- parameter. This action records that payload; built-in blocking remains the
-- preferred enforcement mechanism for supported AI domains.
CREATE OR REPLACE PROCEDURE AGENTIC_GOV_DB.COST_MANAGEMENT.LOG_QUOTA_THRESHOLD(USER_IDS VARCHAR, EVENT_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    CALL AGENTIC_GOV_DB.COST_MANAGEMENT.LOG_BUDGET_THRESHOLD(
        :EVENT_ID, 'AGOV_AI_QUOTA', 'QUOTA_THRESHOLD', 'BUSINESS_ANALYTICS', 100,
        TO_JSON(OBJECT_CONSTRUCT('user_ids', PARSE_JSON(:USER_IDS)))
    );
    RETURN 'Recorded quota event for user IDs ' || :USER_IDS;
END;
$$;

GRANT USAGE ON PROCEDURE AGENTIC_GOV_DB.COST_MANAGEMENT.LOG_QUOTA_THRESHOLD(VARCHAR, VARCHAR)
    TO APPLICATION SNOWFLAKE;

-- Optional: quota custom actions are evaluated against the monthly limit only.
-- CALL AGOV_AI_QUOTA!ADD_CUSTOM_ACTION(
--     SYSTEM$REFERENCE(
--         'PROCEDURE',
--         'AGENTIC_GOV_DB.COST_MANAGEMENT.LOG_QUOTA_THRESHOLD(VARCHAR, VARCHAR)',
--         'SESSION',
--         'USAGE'
--     ),
--     ARRAY_CONSTRUCT('AGOV_AI_QUOTA_100'),
--     'ACTUAL',
--     100
-- );

-- ============================================================================
-- 5.15 DID THE NOTIFICATION GO OUT? (quota events + action log)
--      Run ~10-15 min after 05-03 / 5.14. The event table records quota
--      configuration changes and each notification (INFO = sent, ERROR = e.g.
--      unverified email), so it answers "why no email?" without waiting for
--      ACCOUNT_USAGE.
--      Block-related history (GET_ENFORCEMENT_HISTORY, GET_ACTIVE_BLOCKS_V2,
--      QUOTA_ACCESS_BLOCK_HISTORY) is omitted: Block Enforcement stays OFF.
--      Quota events are visible only to a role with access to the quota and
--      the event table; this block runs as ACCOUNTADMIN so it can read a
--      custom event table too.
-- ACCOUNTADMIN required: reading the default event table here goes through the
-- SNOWFLAKE EVENTS_VIEWER application role and any custom active event table
-- (https://docs.snowflake.com/en/developer-guide/logging-tracing/event-table-setting-up).
-- ============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE AGOV_WH;

-- Quota events go to the account's ACTIVE event table, which is not always
-- the default. Capture it from the EVENT_TABLE parameter with the pipe
-- operator (->>), then read it with IDENTIFIER(). The default table is read
-- through its view, SNOWFLAKE.TELEMETRY.EVENTS_VIEW.
SHOW PARAMETERS LIKE 'EVENT_TABLE' IN ACCOUNT
->> SET EVENT_TBL = (
        SELECT IFF(LOWER("value") = 'snowflake.telemetry.events',
                   'SNOWFLAKE.TELEMETRY.EVENTS_VIEW', "value")
        FROM $1
    );

SELECT $EVENT_TBL AS event_table,
       timestamp,
       record:name::STRING AS event_name,
       value:message::STRING AS message,
       resource_attributes
FROM IDENTIFIER($EVENT_TBL)
WHERE scope['name'] = 'snow.cost.quota'
  AND timestamp >= DATEADD('DAY', -1, CURRENT_TIMESTAMP())
ORDER BY timestamp DESC;
-- Expected after 5.14: QUOTA_NOTIFICATION_THRESHOLD_UPDATED and
-- QUOTA_ADMIN_EMAILS_UPDATED right away, then QUOTA_USER_NOTIFICATION_SENT
-- a few minutes later, once a quota evaluation sees today's spend past 10%
-- (this also happens when the spend crossed 10% before 5.14 ran).
-- "Attempted to send" means sent to the mail system; check the inbox.

USE ROLE AGOV_GOVERNOR;

-- Dry-run rows (5.12b) appear immediately; budget-fired rows only after the
-- budget refresh (hours later) - rerun this in 05-05 time.
SELECT CONTROL_NAME, ACTION_NAME, THRESHOLD, DETAILS:service::STRING AS service,
       DETAILS:dry_run::BOOLEAN AS dry_run, EVENT_TIME
FROM AGENTIC_GOV_DB.COST_MANAGEMENT.AI_BUDGET_ACTION_LOG
ORDER BY EVENT_TIME DESC;
