import { Dashboard } from "@/components/dashboard"

// Required: Snowflake is not reachable during docker build.
export const dynamic = "force-dynamic"

export default function Home() {
  return <Dashboard />
}
