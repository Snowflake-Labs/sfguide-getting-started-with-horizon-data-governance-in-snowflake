# AI Cost Control app - contributor notes

Read-only Next.js dashboard for HOL Part 5 (`hol-lab/05-06-AI-Cost-App-Setup.sql`),
deployed as a Snowflake App with `snow app deploy`. See `README.md` for setup,
local runs, and deployment.

## Commands

```bash
npm ci          # install from package-lock.json
npm run dev     # local dev server on http://localhost:3000
npm test        # vitest run (__tests__/)
npm run build   # production build, as run by app.yml
```

## Conventions

- All SQL lives in `lib/cost-queries.ts`; keep queries read-only and runnable as
  `AGOV_COST_APP_ROLE`.
- `lib/snowflake.ts` is the connection helper from the Snowflake App template.
  Change its auth or pooling behavior only together with
  `__tests__/lib/snowflake.test.ts`.
- `app.yml` holds the build/run phases; `snowflake.yml` holds the deployment target
  (`AGENTIC_GOV_DB.COST_MANAGEMENT.AGOV_AI_COST_CONTROL`).
- `.env.development` pins the local-dev role and warehouse to the lab values.
