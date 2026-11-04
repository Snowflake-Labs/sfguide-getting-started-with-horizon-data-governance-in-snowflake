/**
 * Cost queries for the AI Cost Control app.
 *
 * Every query runs as the app's owner role (AGOV_COST_APP_ROLE, see
 * hol-lab/05-06-AI-Cost-App-Setup.sql). Locally that role is pinned by
 * SNOWFLAKE_ROLE in .env.development.
 *
 * The time window (days) is always parsed to an integer and clamped by
 * parseDays() before it is inlined, so no user text ever reaches the SQL.
 */
import { querySnowflake } from "@/lib/snowflake"

export const SCHEMA = "AGENTIC_GOV_DB.COST_MANAGEMENT"
export const TAG_NAME = "AI_COST_CENTER"

/** Budgets shown in the app (05-02): one per tracked service. */
export const BUDGETS = [
  { name: "AGOV_AGENT_BUDGET", service: "Cortex Agents" },
  { name: "AGOV_AI_FUNCTION_BUDGET", service: "AI Functions" },
] as const

export const QUOTA_NAME = "AGOV_AI_QUOTA"

export function parseDays(raw: string | null, fallback = 30): number {
  const n = Number.parseInt(raw ?? "", 10)
  if (!Number.isFinite(n)) return fallback
  return Math.min(90, Math.max(1, n))
}

/**
 * One row per AI request across every Cortex AI surface:
 *   service, ts, user_name, cost_center, entity, credits
 *
 * cost_center comes from the request-level USER_TAGS when the view has it
 * (point-in-time, what the budget engine sees). AI Functions / Analyst /
 * Search don't carry USER_TAGS, so they use the user's current tag instead.
 * Anything left without a value is UNTAGGED.
 */
export function usageCte(days: number): string {
  const since = `DATEADD('DAY', -${days}, CURRENT_TIMESTAMP())`
  // Views with USER_TAGS: no tag on the request means UNTAGGED - never back-fill
  // with today's tag, or pre-tagging spend would look attributed.
  const tagOf = `COALESCE(FILTER(user_tags, t -> t:tag_name::STRING = '${TAG_NAME}')[0]:tag_value::STRING, 'UNTAGGED')`
  return `
tag_now AS (
  SELECT object_name AS user_name, MAX(tag_value) AS cost_center
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE domain = 'USER' AND tag_database = 'AGENTIC_GOV_DB'
    AND tag_schema = 'COST_MANAGEMENT' AND tag_name = '${TAG_NAME}'
  GROUP BY 1
),
raw AS (
  SELECT 'Cortex Agents' AS service, start_time AS ts, user_name, ${tagOf} AS req_tag,
         agent_name AS entity, token_credits AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY WHERE start_time >= ${since}
  UNION ALL
  SELECT 'Snowflake CoWork', start_time, user_name, ${tagOf},
         COALESCE(agent_name, snowflake_cowork_name), token_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COWORK_USAGE_HISTORY WHERE start_time >= ${since}
  UNION ALL
  SELECT 'CoCo CLI', usage_time::TIMESTAMP_LTZ, user_name, ${tagOf}, 'CLI', token_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY WHERE usage_time >= ${since}
  UNION ALL
  SELECT 'CoCo Desktop', usage_time::TIMESTAMP_LTZ, user_name, ${tagOf}, 'Desktop', token_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_DESKTOP_USAGE_HISTORY WHERE usage_time >= ${since}
  UNION ALL
  SELECT 'CoCo Snowsight', usage_time::TIMESTAMP_LTZ, user_name, ${tagOf}, 'Snowsight', token_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY WHERE usage_time >= ${since}
  UNION ALL
  SELECT 'AI Functions', h.start_time, qh.user_name, NULL, h.function_name, h.credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
    ON qh.query_id = h.query_id AND qh.start_time >= DATEADD('DAY', -${days + 1}, CURRENT_TIMESTAMP())
  WHERE h.start_time >= ${since}
  UNION ALL
  SELECT 'Cortex Analyst', start_time, username, NULL, 'Analyst', credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY WHERE start_time >= ${since}
  UNION ALL
  SELECT 'Cortex Search', usage_date::TIMESTAMP_LTZ, NULL, NULL, service_name, credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY WHERE usage_date >= ${since}::DATE
  UNION ALL
  SELECT 'AI Guardrails', usage_time::TIMESTAMP_LTZ, user_name, ${tagOf}, agentic_source, token_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_GUARDRAILS_USAGE_HISTORY WHERE usage_time >= ${since}
  UNION ALL
  SELECT 'Document Processing', d.start_time::TIMESTAMP_LTZ, qh.user_name, NULL, d.function_name, d.credits_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY d
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
    ON qh.query_id = d.query_id AND qh.start_time >= DATEADD('DAY', -${days + 1}, CURRENT_TIMESTAMP())
  WHERE d.start_time >= ${since}
  UNION ALL
  SELECT 'Fine-tuning', start_time::TIMESTAMP_LTZ, NULL, NULL, model_name, token_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FINE_TUNING_USAGE_HISTORY WHERE start_time >= ${since}
  UNION ALL
  SELECT 'Provisioned Throughput', interval_start_time::TIMESTAMP_LTZ, NULL, NULL, model_name, ptu_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_PROVISIONED_THROUGHPUT_USAGE_HISTORY WHERE interval_start_time >= ${since}
  UNION ALL
  SELECT 'AI Gateway', start_time::TIMESTAMP_LTZ, NULL, NULL, gateway_name, credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.AI_GATEWAY_USAGE_HISTORY WHERE start_time >= ${since}
  -- CORTEX_REST_API_USAGE_HISTORY has TOKENS only (no credits): covered by
  -- METERING_HISTORY (meteringByService), not summed here.
),
usage AS (
  SELECT r.service, r.ts, COALESCE(r.user_name, '(service-level)') AS user_name,
         COALESCE(r.req_tag, t.cost_center, 'UNTAGGED') AS cost_center,
         r.entity, COALESCE(r.credits, 0) AS credits
  FROM raw r LEFT JOIN tag_now t ON t.user_name = r.user_name
)`
}

const num = (v: unknown) => Number(v ?? 0)

/**
 * Whole-account view: Cortex AI service types in METERING_HISTORY (billing
 * numbers, no user detail). Pattern match so new AI service types appear
 * automatically. In LIKE, `_` matches any one character - fine for these names.
 */
export async function meteringByService(days: number) {
  const rows = await querySnowflake(`
SELECT service_type, SUM(credits_used) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD('DAY', -${days}, CURRENT_TIMESTAMP())
  AND (service_type ILIKE 'CORTEX%' OR service_type ILIKE 'AI_%'
       OR service_type ILIKE 'SNOWFLAKE_COCO%' OR service_type ILIKE '%INTELLIGENCE%'
       OR service_type ILIKE '%COWORK%')
GROUP BY 1 ORDER BY credits DESC`)
  return rows.map((r) => ({ serviceType: r.SERVICE_TYPE as string, credits: num(r.CREDITS) }))
}

export async function dailyByService(days: number) {
  const rows = await querySnowflake(`
WITH ${usageCte(days)}
SELECT TO_CHAR(DATE_TRUNC('DAY', ts), 'YYYY-MM-DD') AS day, service, SUM(credits) AS credits
FROM usage GROUP BY 1, 2 ORDER BY 1, 2`)
  return rows.map((r) => ({ day: r.DAY as string, service: r.SERVICE as string, credits: num(r.CREDITS) }))
}

export async function byCostCenter(days: number) {
  const rows = await querySnowflake(`
WITH ${usageCte(days)}
SELECT cost_center, service, user_name, SUM(credits) AS credits, COUNT(*) AS requests
FROM usage GROUP BY 1, 2, 3 ORDER BY credits DESC`)
  return rows.map((r) => ({
    costCenter: r.COST_CENTER as string,
    service: r.SERVICE as string,
    user: r.USER_NAME as string,
    credits: num(r.CREDITS),
    requests: num(r.REQUESTS),
  }))
}

/** Per-user AI credits next to warehouse credits (QUERY_ATTRIBUTION_HISTORY). */
export async function usersAiVsWarehouse(days: number) {
  const rows = await querySnowflake(`
WITH ${usageCte(days)},
ai AS (
  SELECT user_name, MAX_BY(cost_center, ts) AS cost_center, SUM(credits) AS ai_credits
  FROM usage WHERE user_name <> '(service-level)' GROUP BY 1
),
wh AS (
  SELECT user_name,
         SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS wh_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD('DAY', -${days}, CURRENT_TIMESTAMP())
  GROUP BY 1
)
SELECT ai.user_name, ai.cost_center, ai.ai_credits, COALESCE(wh.wh_credits, 0) AS wh_credits
FROM ai LEFT JOIN wh ON wh.user_name = ai.user_name
ORDER BY ai.ai_credits DESC LIMIT 25`)
  return rows.map((r) => ({
    user: r.USER_NAME as string,
    costCenter: r.COST_CENTER as string,
    aiCredits: num(r.AI_CREDITS),
    whCredits: num(r.WH_CREDITS),
  }))
}

/** Credits by model: AI Functions (model_name) + CoCo (credits_granular keys). */
export async function byModel(days: number) {
  const since = `DATEADD('DAY', -${days}, CURRENT_TIMESTAMP())`
  const rows = await querySnowflake(`
WITH coco AS (
  SELECT credits_granular FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_DESKTOP_USAGE_HISTORY WHERE usage_time >= ${since}
  UNION ALL SELECT credits_granular FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY WHERE usage_time >= ${since}
  UNION ALL SELECT credits_granular FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY WHERE usage_time >= ${since}
),
models AS (
  SELECT 'CoCo' AS service, m.key AS model,
         COALESCE(m.value:input::FLOAT, 0) + COALESCE(m.value:output::FLOAT, 0)
         + COALESCE(m.value:cache_read_input::FLOAT, 0) + COALESCE(m.value:cache_write_input::FLOAT, 0) AS credits
  FROM coco, LATERAL FLATTEN(input => credits_granular) m
  UNION ALL
  SELECT 'AI Functions', COALESCE(NULLIF(model_name, ''), '(n/a)'), credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY WHERE start_time >= ${since}
)
SELECT service, model, SUM(credits) AS credits FROM models
GROUP BY 1, 2 HAVING SUM(credits) > 0 ORDER BY credits DESC LIMIT 20`)
  return rows.map((r) => ({ service: r.SERVICE as string, model: r.MODEL as string, credits: num(r.CREDITS) }))
}

export type BudgetStatus = {
  name: string
  service: string
  available: boolean
  limit: number | null
  used: number
  byService: { serviceType: string; credits: number }[]
  error?: string
}

/** Current-month status of each budget. Missing / inaccessible budgets are reported, not thrown. */
export async function budgetStatus(): Promise<BudgetStatus[]> {
  const month = `TO_CHAR(CURRENT_DATE(), 'YYYY-MM')`
  return Promise.all(
    BUDGETS.map(async (b) => {
      const fqn = `${SCHEMA}.${b.name}`
      try {
        const [limitRows, usageRows] = await Promise.all([
          querySnowflake(`CALL ${fqn}!GET_SPENDING_LIMIT()`),
          querySnowflake(
            `CALL ${fqn}!GET_SERVICE_TYPE_USAGE_V2(${month}, ${month})
             ->> SELECT "SERVICE_TYPE" AS service_type, SUM("CREDITS_USED") AS credits FROM $1 GROUP BY 1`,
          ),
        ])
        const limit = Number(Object.values(limitRows[0] ?? {})[0])
        const byService = usageRows.map((r) => ({ serviceType: r.SERVICE_TYPE as string, credits: num(r.CREDITS) }))
        return {
          ...b,
          available: true,
          limit: Number.isFinite(limit) ? limit : null,
          used: byService.reduce((s, r) => s + r.credits, 0),
          byService,
        }
      } catch (e) {
        return {
          ...b,
          available: false,
          limit: null,
          used: 0,
          byService: [],
          error: e instanceof Error ? e.message.split("\n")[0] : String(e),
        }
      }
    }),
  )
}

/** Current-month quota spend per user and service, plus the per-user limits. */
export async function quotaStatus() {
  const fqn = `${SCHEMA}.${QUOTA_NAME}`
  try {
    const [spend, config] = await Promise.all([
      querySnowflake(
        `CALL ${fqn}!GET_SPENDING_DETAILS_BY_USERS(
           TO_CHAR(DATE_TRUNC('MONTH', CURRENT_DATE()), 'YYYY-MM-DD'),
           TO_CHAR(LAST_DAY(CURRENT_DATE()), 'YYYY-MM-DD'))
         ->> SELECT "USER_NAME" AS user_name, "SERVICE_TYPE" AS service_type, SUM("CREDITS_SPEND") AS credits
             FROM $1 GROUP BY 1, 2 ORDER BY 3 DESC`,
      ),
      querySnowflake(`CALL ${fqn}!GET_CONFIG()`),
    ])
    return {
      available: true,
      config: Object.values(config[0] ?? {})[0] ?? null,
      rows: spend.map((r) => ({ user: r.USER_NAME as string, serviceType: r.SERVICE_TYPE as string, credits: num(r.CREDITS) })),
    }
  } catch (e) {
    return { available: false, config: null, rows: [], error: e instanceof Error ? e.message.split("\n")[0] : String(e) }
  }
}
