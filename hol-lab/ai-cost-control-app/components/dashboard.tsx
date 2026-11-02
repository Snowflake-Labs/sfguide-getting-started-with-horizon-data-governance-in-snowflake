"use client"

import { useMemo, useState } from "react"
import { useQuery } from "@tanstack/react-query"
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Skeleton } from "@/components/ui/skeleton"
import { Button } from "@/components/ui/button"
import { ChartTooltip, formatTick, getYAxisWidth } from "@/components/chart-utils"

type Daily = { day: string; service: string; credits: number }
type CostCenterRow = { costCenter: string; service: string; user: string; credits: number; requests: number }
type UserRow = { user: string; costCenter: string; aiCredits: number; whCredits: number }
type ModelRow = { service: string; model: string; credits: number }
type MeteringRow = { serviceType: string; credits: number }
type Budget = {
  name: string
  service: string
  available: boolean
  limit: number | null
  used: number
  byService: { serviceType: string; credits: number }[]
  error?: string
}
type Quota = { available: boolean; rows: { user: string; serviceType: string; credits: number }[]; error?: string }

const SERVICES = [
  "Cortex Agents",
  "AI Functions",
  "Snowflake CoWork",
  "CoCo CLI",
  "CoCo Desktop",
  "CoCo Snowsight",
  "Cortex Analyst",
  "Cortex Search",
  "AI Guardrails",
  "Document Processing",
  "Fine-tuning",
  "Provisioned Throughput",
  "AI Gateway",
]
const COLORS = ["#29B5E8", "#11567F", "#FF9F36", "#7254A3", "#D45B90", "#8A999E", "#71D3DC", "#5B5B5B", "#3F9C35", "#C7A600", "#A0522D", "#6A5ACD", "#2F4F4F"]
const colorOf = (s: string) => COLORS[Math.max(0, SERVICES.indexOf(s)) % COLORS.length]
const fmt = (n: number) => n.toLocaleString(undefined, { maximumFractionDigits: n < 10 ? 3 : 1 })

async function fetchView<T>(view: string, days: number): Promise<T> {
  const res = await fetch(`/api/${view}?days=${days}`)
  const body = await res.json()
  if (!res.ok) throw new Error(body.error ?? res.statusText)
  return body.data as T
}

function useView<T>(view: string, days: number) {
  return useQuery({ queryKey: [view, days], queryFn: () => fetchView<T>(view, days), staleTime: 5 * 60_000 })
}

function Panel({
  title,
  description,
  q,
  children,
}: {
  title: string
  description?: string
  q: { isLoading: boolean; error: unknown }
  children: React.ReactNode
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        {description && <CardDescription>{description}</CardDescription>}
      </CardHeader>
      <CardContent>
        {q.isLoading ? (
          <Skeleton className="h-64 w-full" />
        ) : q.error ? (
          <Alert variant="destructive">
            <AlertTitle>Query failed</AlertTitle>
            <AlertDescription>{(q.error as Error).message}</AlertDescription>
          </Alert>
        ) : (
          children
        )}
      </CardContent>
    </Card>
  )
}

function Kpi({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <Card>
      <CardContent className="pt-6">
        <p className="text-xs text-muted-foreground">{label}</p>
        <p className="text-2xl font-semibold">{value}</p>
        {sub && <p className="text-xs text-muted-foreground mt-1">{sub}</p>}
      </CardContent>
    </Card>
  )
}

export function Dashboard() {
  const [days, setDays] = useState(30)
  const daily = useView<Daily[]>("daily", days)
  const centers = useView<CostCenterRow[]>("cost-centers", days)
  const users = useView<UserRow[]>("users", days)
  const models = useView<ModelRow[]>("models", days)
  const metering = useView<MeteringRow[]>("metering", days)
  const budgets = useView<{ budgets: Budget[]; quota: Quota }>("budgets", days)

  // Pivot daily rows into one object per day for a stacked area chart.
  const { dailyWide, servicesPresent, totals } = useMemo(() => {
    const byDay = new Map<string, Record<string, number | string>>()
    const totals = new Map<string, number>()
    for (const r of daily.data ?? []) {
      const row = byDay.get(r.day) ?? { day: r.day }
      row[r.service] = r.credits
      byDay.set(r.day, row)
      totals.set(r.service, (totals.get(r.service) ?? 0) + r.credits)
    }
    const present = SERVICES.filter((s) => totals.has(s))
    const wide = [...byDay.values()].map((row) => {
      for (const s of present) row[s] ??= 0
      return row
    })
    return { dailyWide: wide, servicesPresent: present, totals }
  }, [daily.data])

  const grandTotal = [...totals.values()].reduce((a, b) => a + b, 0)

  // Cost center x service, stacked bars.
  const { centerWide, centerServices, untagged } = useMemo(() => {
    const byCenter = new Map<string, Record<string, number | string>>()
    const svc = new Set<string>()
    for (const r of centers.data ?? []) {
      const row = byCenter.get(r.costCenter) ?? { costCenter: r.costCenter }
      row[r.service] = ((row[r.service] as number) ?? 0) + r.credits
      byCenter.set(r.costCenter, row)
      svc.add(r.service)
    }
    const untagged = (centers.data ?? []).filter((r) => r.costCenter === "UNTAGGED" && r.credits > 0)
    return {
      centerWide: [...byCenter.values()],
      centerServices: SERVICES.filter((s) => svc.has(s)),
      untagged,
    }
  }, [centers.data])

  const untaggedTotal = untagged.reduce((a, r) => a + r.credits, 0)

  return (
    <main className="w-full py-8 px-4 space-y-6">
      <div className="flex flex-wrap items-center gap-3">
        <div className="mr-auto">
          <h1 className="text-xl font-semibold">Cortex AI spend across every surface</h1>
          <p className="text-sm text-muted-foreground">
            ACCOUNT_USAGE views lag up to a few hours; budget figures refresh on the budget schedule.
          </p>
        </div>
        {[7, 30, 90].map((d) => (
          <Button key={d} size="sm" variant={d === days ? "default" : "outline"} onClick={() => setDays(d)}>
            {d} days
          </Button>
        ))}
      </div>

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <Kpi label={`AI credits, last ${days} days`} value={daily.data ? fmt(grandTotal) : "…"} />
        <Kpi
          label="Top service"
          value={servicesPresent.length ? [...totals.entries()].sort((a, b) => b[1] - a[1])[0][0] : "…"}
        />
        <Kpi
          label="UNTAGGED credits"
          value={centers.data ? fmt(untaggedTotal) : "…"}
          sub={grandTotal > 0 && centers.data ? `${((untaggedTotal / grandTotal) * 100).toFixed(1)}% of AI spend` : undefined}
        />
        <Kpi
          label={`METERING_HISTORY total, last ${days} days`}
          value={metering.data ? fmt(metering.data.reduce((a, r) => a + r.credits, 0)) : "…"}
          sub="Billing view of all Cortex AI service types"
        />
      </div>

      <Panel
        title="Whole picture - METERING_HISTORY"
        description="One row per service type, the numbers billing uses. For user / tag / model detail, each service has its own usage view (panels below)."
        q={metering}
      >
        <ResponsiveContainer width="100%" height={240}>
          <BarChart data={metering.data ?? []} layout="vertical" margin={{ left: 60 }}>
            <CartesianGrid strokeDasharray="3 3" opacity={0.3} />
            <XAxis type="number" fontSize={12} tickFormatter={formatTick} />
            <YAxis type="category" dataKey="serviceType" fontSize={11} width={190} />
            <Tooltip content={<ChartTooltip />} />
            <Bar dataKey="credits" name="Credits" fill="#29B5E8" />
          </BarChart>
        </ResponsiveContainer>
      </Panel>

      <Panel title="Daily credits by service" description="Per-service usage views, stacked by Cortex AI surface" q={daily}>
        <ResponsiveContainer width="100%" height={300}>
          <AreaChart data={dailyWide}>
            <CartesianGrid strokeDasharray="3 3" opacity={0.3} />
            <XAxis dataKey="day" fontSize={12} />
            <YAxis fontSize={12} width={getYAxisWidth(dailyWide.map((r) => ({ v: servicesPresent.reduce((a, s) => a + Number(r[s] ?? 0), 0) })), "v")} tickFormatter={formatTick} />
            <Tooltip content={<ChartTooltip />} />
            <Legend />
            {servicesPresent.map((s) => (
              <Area key={s} type="monotone" dataKey={s} stackId="1" stroke={colorOf(s)} fill={colorOf(s)} fillOpacity={0.6} />
            ))}
          </AreaChart>
        </ResponsiveContainer>
      </Panel>

      <div className="grid grid-cols-1 xl:grid-cols-2 gap-6">
        <Panel
          title="Credits by cost center"
          description="AI_COST_CENTER user tag. Request-level USER_TAGS where available, else the user's current tag."
          q={centers}
        >
          <ResponsiveContainer width="100%" height={280}>
            <BarChart data={centerWide} layout="vertical" margin={{ left: 40 }}>
              <CartesianGrid strokeDasharray="3 3" opacity={0.3} />
              <XAxis type="number" fontSize={12} tickFormatter={formatTick} />
              <YAxis type="category" dataKey="costCenter" fontSize={12} width={140} />
              <Tooltip content={<ChartTooltip />} />
              <Legend />
              {centerServices.map((s) => (
                <Bar key={s} dataKey={s} stackId="c" fill={colorOf(s)} />
              ))}
            </BarChart>
          </ResponsiveContainer>
        </Panel>

        <Panel
          title="UNTAGGED spend"
          description="Who to tag next. Requests made before tagging stay UNTAGGED (point-in-time)."
          q={centers}
        >
          {untagged.length === 0 ? (
            <p className="text-sm text-muted-foreground">Every credit in this window is attributed.</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>User</TableHead>
                  <TableHead>Service</TableHead>
                  <TableHead className="text-right">Requests</TableHead>
                  <TableHead className="text-right">Credits</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {untagged.slice(0, 10).map((r) => (
                  <TableRow key={`${r.user}-${r.service}`}>
                    <TableCell>{r.user}</TableCell>
                    <TableCell>{r.service}</TableCell>
                    <TableCell className="text-right">{r.requests.toLocaleString()}</TableCell>
                    <TableCell className="text-right">{fmt(r.credits)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </Panel>
      </div>

      <Panel title="Budgets - current month" description="05-02: one budget per tracked service, scoped by shared resource + user tag" q={budgets}>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {(budgets.data?.budgets ?? []).map((b) => {
            const pct = b.limit ? Math.min(100, (b.used / b.limit) * 100) : 0
            return (
              <div key={b.name} className="rounded-md border border-border p-4 space-y-2">
                <div className="flex items-center gap-2">
                  <span className="text-sm font-semibold">{b.service}</span>
                </div>
                <p className="text-xs text-muted-foreground font-mono">{b.name}</p>
                {b.available ? (
                  <>
                    <p className="text-lg font-semibold">
                      {fmt(b.used)} <span className="text-sm text-muted-foreground">/ {b.limit ?? "-"} credits</span>
                    </p>
                    <div className="h-2 w-full rounded bg-muted">
                      <div
                        className="h-2 rounded"
                        style={{ width: `${pct}%`, background: pct >= 80 ? "#D45B90" : "#29B5E8" }}
                      />
                    </div>
                    <p className="text-xs text-muted-foreground">{pct.toFixed(1)}% used (custom action at 80%)</p>
                  </>
                ) : (
                  <p className="text-xs text-muted-foreground">
                    Not created or not granted to the app role (run 05-02, then 05-06).
                  </p>
                )}
              </div>
            )
          })}
        </div>
      </Panel>

      <div className="grid grid-cols-1 xl:grid-cols-2 gap-6">
        <Panel title="AI vs warehouse credits per user" description="AI = all services above; WH = QUERY_ATTRIBUTION_HISTORY" q={users}>
          <ResponsiveContainer width="100%" height={300}>
            <BarChart data={(users.data ?? []).slice(0, 10)}>
              <CartesianGrid strokeDasharray="3 3" opacity={0.3} />
              <XAxis dataKey="user" fontSize={11} />
              <YAxis fontSize={12} width={getYAxisWidth(users.data ?? [], "aiCredits")} tickFormatter={formatTick} />
              <Tooltip content={<ChartTooltip />} />
              <Legend />
              <Bar dataKey="aiCredits" name="AI credits" fill="#29B5E8" />
              <Bar dataKey="whCredits" name="Warehouse credits" fill="#11567F" />
            </BarChart>
          </ResponsiveContainer>
        </Panel>

        <Panel title="Credits by model" description="AI Functions (model_name) and CoCo (credits_granular)" q={models}>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Model</TableHead>
                <TableHead>Service</TableHead>
                <TableHead className="text-right">Credits</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {(models.data ?? []).slice(0, 12).map((m) => (
                <TableRow key={`${m.service}-${m.model}`}>
                  <TableCell className="font-mono text-xs">{m.model}</TableCell>
                  <TableCell>{m.service}</TableCell>
                  <TableCell className="text-right">{fmt(m.credits)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </Panel>
      </div>

      <Panel title={`Per-user quota - ${"AGOV_AI_QUOTA"}`} description="Cortex Agents + AI Functions, current month" q={budgets}>
        {!budgets.data?.quota.available ? (
          <p className="text-sm text-muted-foreground">Quota not available: {budgets.data?.quota.error}</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>User</TableHead>
                <TableHead>Service</TableHead>
                <TableHead className="text-right">Credits</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {budgets.data.quota.rows.map((r) => (
                <TableRow key={`${r.user}-${r.serviceType}`}>
                  <TableCell>{r.user}</TableCell>
                  <TableCell>{r.serviceType}</TableCell>
                  <TableCell className="text-right">{fmt(r.credits)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </Panel>
    </main>
  )
}
