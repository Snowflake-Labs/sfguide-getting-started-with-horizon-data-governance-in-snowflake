#!/usr/bin/env python3
"""
run_agent.py - Prove the approved Cortex Agent stays governed even over the REST API.

The agent is created in SQL (02-01). It can be run from SQL (02-02 / 02-03), manually in
Snowflake CoWork (formerly Snowflake Intelligence), or - as shown here - over the REST API.
This script is the OPTIONAL programmatic proof: it mints a short-lived key-pair JWT from your
Snowflake CLI connection and calls the Cortex Agents agent:run endpoint directly. Agent
Identity exclusion, fine-grained access control, and model RBAC are all enforced server-side,
and the call leaves the same cortex-agent-{request_id} fingerprint in QUERY_HISTORY as any
other invocation.

Usage:
    python run_agent.py --connection my_conn --role AGOV_ANALYST
    python run_agent.py --connection my_conn --role AGOV_GOVERNOR "How many orders do we have?"

The requested role is sent explicitly. Verify the actual agent SQL role in query history;
a successful response alone does not prove that the expected policy branch was used.
"""

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request

AGENT_PATH = "databases/AGENTIC_GOV_DB/schemas/AGENTS/agents/CUSTOMER_INSIGHTS_AGENT"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise urllib.error.HTTPError(request.full_url, code, "Redirect refused", headers, response)


def sh(args: list[str]) -> str:
    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit("Snowflake CLI command failed; check the selected connection and role locally.")
    return proc.stdout.strip()


def render_response(payload, headers):
    for block in payload.get("content", []):
        if block.get("type") == "text":
            print(block.get("text", ""))
        else:
            print(json.dumps(block, indent=2))
    request_id = headers.get("X-Snowflake-Request-Id") or payload.get("request_id") or payload.get("metadata", {}).get("request_id")
    if request_id:
        print(f"\nrequest_id: {request_id}")
    else:
        print("\nRequest identifier was not returned. Correlate the call timestamp and user in query history; do not infer a run ID.")
    return request_id


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connection", required=True)
    parser.add_argument("--role", required=True)
    parser.add_argument("question", nargs="?", default="What is total revenue by state? Top 3 only.")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", args.role):
        parser.error("Use an unquoted Snowflake role identifier.")
    role = args.role.upper()
    out = sh(["snow", "sql", "-c", args.connection, "--role", role, "--format", "json", "-q",
              "SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS HOST, CURRENT_ROLE() AS ROLE_NAME, CURRENT_USER() AS USER_NAME, CURRENT_TIMESTAMP() AS CALLED_AT"])
    identity = json.loads(out)[-1]
    if identity["ROLE_NAME"] != role:
        sys.exit("Role verification failed; no agent request sent.")
    host = identity["HOST"].lower().replace("_", "-")
    if not re.fullmatch(r"[a-z0-9-]+", host):
        sys.exit("Invalid account hostname; no agent request sent.")
    print(json.dumps(identity, indent=2))
    jwt = sh(["snow", "connection", "generate-jwt", "-c", args.connection]).splitlines()[-1].strip()
    url = f"https://{host}.snowflakecomputing.com/api/v2/{AGENT_PATH}:run"

    body = json.dumps({
        "messages": [{"role": "user", "content": [{"type": "text", "text": args.question}]}],
        "stream": False,
    }).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Authorization": f"Bearer {jwt}",
        "X-Snowflake-Authorization-Token-Type": "KEYPAIR_JWT",
        "X-Snowflake-Role": role,
        "Content-Type": "application/json",
        "Accept": "application/json",
    })

    print(f"POST {url}\nRequested role: {role}\nQ: {args.question}\n")
    try:
        with urllib.request.build_opener(NoRedirect()).open(req, timeout=180) as resp:
            payload = json.loads(resp.read().decode())
            response_headers = resp.headers
    except urllib.error.HTTPError as e:
        sys.exit(f"Agent request failed with HTTP {e.code}; no successful governance result.")
    except urllib.error.URLError:
        sys.exit("Agent request failed before a response was received.")

    render_response(payload, response_headers)
    print(
        "\nVerify the actual ROLE_NAME and tool SQL in QUERY_HISTORY, correlated to this request\n"
        "and timestamp. Compare returned tool data with the expected persona result.\n"
        "See hol-lab/02-03-Agent-Identity.sql, section 02-03.4."
    )


if __name__ == "__main__":
    main()
