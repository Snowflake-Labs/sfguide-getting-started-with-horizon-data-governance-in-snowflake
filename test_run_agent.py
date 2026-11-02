import contextlib
import io
import json
import unittest
from unittest.mock import patch

import run_agent


class AgentHelperTests(unittest.TestCase):
    def test_renders_structured_blocks_without_truncation(self):
        output = io.StringIO()
        payload = {"content": [{"type": "text", "text": "Answer"},
                               {"type": "table", "data": [["USD", 30000, "x" * 2000]]}],
                   "request_id": "request-123"}
        with contextlib.redirect_stdout(output):
            request_id = run_agent.render_response(payload, {})
        self.assertEqual(request_id, "request-123")
        self.assertIn("30000", output.getvalue())
        self.assertIn("Answer", output.getvalue())
        self.assertIn("x" * 2000, output.getvalue())

    def test_response_header_identifier_takes_precedence(self):
        with contextlib.redirect_stdout(io.StringIO()):
            request_id = run_agent.render_response(
                {"content": [], "request_id": "body-id"},
                {"X-Snowflake-Request-Id": "header-id"})
        self.assertEqual(request_id, "header-id")

    def test_missing_identifier_is_explicit(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            request_id = run_agent.render_response({"content": []}, {})
        self.assertIsNone(request_id)
        self.assertIn("not returned", output.getvalue())
        self.assertNotIn("run_id: None", output.getvalue())

    def test_cli_failure_does_not_echo_credentials(self):
        with patch("run_agent.subprocess.run") as execute:
            execute.return_value.returncode = 1
            execute.return_value.stderr = "secret-token"
            with self.assertRaises(SystemExit) as error:
                run_agent.sh(["snow", "secret-token"])
        self.assertNotIn("secret-token", str(error.exception))

    def test_role_mismatch_stops_before_jwt_or_request(self):
        identity = json.dumps([{"HOST": "ORG-ACCOUNT", "ROLE_NAME": "ACCOUNTADMIN"}])
        with patch("sys.argv", ["run_agent.py", "--connection", "demo", "--role", "AGOV_ANALYST"]), \
             patch("run_agent.sh", return_value=identity) as command, \
             patch("run_agent.urllib.request.build_opener") as request:
            with self.assertRaises(SystemExit):
                run_agent.main()
        self.assertEqual(command.call_count, 1)
        request.assert_not_called()

    def test_invalid_role_stops_before_cli(self):
        with patch("sys.argv", ["run_agent.py", "--connection", "demo", "--role", "role\r\nInjected: true"]), \
             patch("run_agent.sh") as command, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                run_agent.main()
        command.assert_not_called()

    def test_explicit_role_header_sent(self):
        identity = json.dumps([{"HOST": "ORG-ACCOUNT", "ROLE_NAME": "AGOV_ANALYST", "USER_NAME": "USER", "CALLED_AT": "now"}])
        with patch("sys.argv", ["run_agent.py", "--connection", "demo", "--role", "agov_analyst"]), \
             patch("run_agent.sh", side_effect=[identity, "test-jwt"]), \
             patch("run_agent.urllib.request.build_opener") as opener, \
             contextlib.redirect_stdout(io.StringIO()):
            request = opener.return_value.open
            response = request.return_value.__enter__.return_value
            response.read.return_value = b'{"content": [], "request_id": "abc"}'
            response.headers = {}
            run_agent.main()
        sent = request.call_args.args[0]
        self.assertEqual(sent.get_header("X-snowflake-role"), "AGOV_ANALYST")
        self.assertEqual(sent.full_url, "https://org-account.snowflakecomputing.com/api/v2/" + run_agent.AGENT_PATH + ":run")

    def test_redirects_are_refused(self):
        request = run_agent.urllib.request.Request("https://demo.snowflakecomputing.com", headers={"Authorization": "Bearer secret"})
        with self.assertRaises(run_agent.urllib.error.HTTPError) as error:
            run_agent.NoRedirect().redirect_request(request, None, 302, "redirect", {}, "https://other.example")
        error.exception.close()


if __name__ == '__main__':
    unittest.main()