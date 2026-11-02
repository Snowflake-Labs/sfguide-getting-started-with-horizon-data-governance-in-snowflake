// GET /api/<view>?days=N  — JSON data for one dashboard panel.
// view: daily | cost-centers | users | models | metering | budgets

import {
  budgetStatus,
  byCostCenter,
  byModel,
  dailyByService,
  meteringByService,
  parseDays,
  quotaStatus,
  usersAiVsWarehouse,
} from "@/lib/cost-queries"

// Required: Snowflake is not reachable during docker build.
export const dynamic = "force-dynamic"

const VIEWS: Record<string, (days: number) => Promise<unknown>> = {
  daily: dailyByService,
  "cost-centers": byCostCenter,
  users: usersAiVsWarehouse,
  models: byModel,
  metering: meteringByService,
  budgets: async () => ({ budgets: await budgetStatus(), quota: await quotaStatus() }),
}

export async function GET(request: Request, ctx: { params: Promise<{ view: string }> }) {
  const { view } = await ctx.params
  const handler = VIEWS[view]
  if (!handler) return Response.json({ error: `Unknown view: ${view}` }, { status: 404 })
  const days = parseDays(new URL(request.url).searchParams.get("days"))
  try {
    return Response.json({ days, data: await handler(days) })
  } catch (e) {
    const message = e instanceof Error ? e.message : "Unknown error"
    return Response.json({ error: message }, { status: 500 })
  }
}
