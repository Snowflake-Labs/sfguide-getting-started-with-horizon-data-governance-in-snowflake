# AI Cost Control (HOL Part 5, optional 05-06)

A Snowflake App (Next.js on Snowflake App Runtime) that shows Cortex AI spend
across every surface, on top of the controls built in 05-01 .. 05-05:

| Panel | Source |
|---|---|
| Whole picture: credits per AI service type | `METERING_HISTORY` (billing numbers, no user detail) |
| Daily credits by service (Agents, AI Functions, CoWork, CoCo CLI/Desktop/Snowsight, Analyst, Search) | each service's own `SNOWFLAKE.ACCOUNT_USAGE.*_USAGE_HISTORY` view |
| Credits by cost center + UNTAGGED spend | `AI_COST_CENTER` user tag (request `USER_TAGS`, else `TAG_REFERENCES`) |
| Budgets, current month | `<budget>!GET_SPENDING_LIMIT()`, `<budget>!GET_SERVICE_TYPE_USAGE_V2()` |
| Per-user quota spend (limits are not shown) | `AGOV_AI_QUOTA!GET_SPENDING_DETAILS_BY_USERS()` |
| AI vs warehouse credits per user | usage views + `QUERY_ATTRIBUTION_HISTORY` |
| Credits by model | AI Functions `model_name`, CoCo `credits_granular` |

Everything is read-only and runs as `AGOV_COST_APP_ROLE`.

## Attribution rules shown by the app

- **Point-in-time.** CoCo, CoWork and Agents record the caller's user tags on
  each request. A request made before the user was tagged stays `UNTAGGED`,
  exactly as the budget engine sees it.
- **CoCo ignores QUERY_TAG.** CoCo overwrites the session query tag, so only
  user tags can attribute CoCo spend.
- **Entry point decides.** An agent called from a CoWork chat is billed to
  CoWork, not to Cortex Agents.
- AI Functions, Analyst and Search don't carry `USER_TAGS`; the app uses the
  user's current tag for them. Search is service-level (no user).

## Prerequisites

1. Run `hol-lab/05-01` .. `05-05` (05-05 section 5.22 is optional).
2. Run `hol-lab/05-06-AI-Cost-App-Setup.sql` as ACCOUNTADMIN.
3. Node.js 22 LTS (22.12 or later) or 24 LTS, matching the engine ranges in
   `package-lock.json`, and Snowflake CLI **3.21 or later** for deployment
   (`snow app setup --help` must work).

## Run locally (CoCo Desktop terminal)

```bash
cd hol-lab/ai-cost-control-app
npm install
npm run dev            # http://localhost:3000
```

The app uses your default connection in `~/.snowflake/connections.toml`
(or `config.toml`). `.env.development` pins the role to `AGOV_COST_APP_ROLE`
and the warehouse to `AGOV_WH`.

If the lab account isn't your default connection, pick it explicitly with
`SNOWFLAKE_CONNECTION_NAME`. The helper in `lib/snowflake.ts` lets shell
variables take precedence over the TOML connection: `SNOWFLAKE_USER` +
`SNOWFLAKE_PASSWORD` switch to password auth, and `SNOWFLAKE_ACCOUNT`,
`SNOWFLAKE_ACCOUNT_URL`, or `SNOWFLAKE_HOST` redirect the account. Some IDE
terminals export these, so clear them for the run:

```bash
env -u SNOWFLAKE_USER -u SNOWFLAKE_PASSWORD -u SNOWFLAKE_ACCOUNT \
    -u SNOWFLAKE_ACCOUNT_URL -u SNOWFLAKE_HOST \
    SNOWFLAKE_CONNECTION_NAME=<lab_connection> npm run dev
```

Quick check: `curl "http://localhost:3000/api/budgets"` returns
`{"days": 30, "data": {"budgets": [...], "quota": {...}}}` with
`"available": true` on both budgets and the quota.

## Deploy to Snowflake

`snowflake.yml` (deployment target) and `app.yml` (build/run + label/icon)
are already generated for `AGENTIC_GOV_DB.COST_MANAGEMENT.AGOV_AI_COST_CONTROL`.

```bash
snow app deploy -c <lab_connection> --role AGOV_COST_APP_ROLE --verbose
```

Open the URL printed at the end. Remove with `99-Teardown.sql`.

## API

`GET /api/<view>?days=7|30|90` where view is `daily`, `cost-centers`,
`users`, `models`, `metering` or `budgets`. `days` defaults to 30 and is
clamped to 1..90. Responses are `{ days, data }`; `budgets` returns
`data: { budgets, quota }`.

## Code map

- `lib/cost-queries.ts` - all SQL (unified usage CTE, budget/quota calls)
- `app/api/[view]/route.ts` - JSON endpoints
- `components/dashboard.tsx` - charts and tables (recharts)
- `lib/snowflake.ts` - connection helper from the Snowflake App template
