#!/usr/bin/env python3
"""Two agents and one read-only MCP tool for a routed FortiGate lab."""

import argparse
import itertools
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener
from uuid import uuid4

A2A_TYPE = "application/a2a+json"
MCP_VERSION = "2025-11-25"
OPENAI_URL = "https://api.openai.com/v1/responses"
# Use the VM's routing table even if its shell has proxy variables.
DIRECT = build_opener(ProxyHandler({}))
SERVICE = "payments-demo"
TOOL = {
    "name": "get_service_status",
    "description": "Return the status of the synthetic lab service.",
    "inputSchema": {
        "type": "object",
        "properties": {"service": {"type": "string", "enum": [SERVICE]}},
        "required": ["service"],
        "additionalProperties": False,
    },
}


def request_json(url, body=None, *, headers=None, timeout=30):
    data = None if body is None else json.dumps(body).encode()
    req = Request(url, data=data, headers={"Content-Type": "application/json", **(headers or {})})
    print(f"-> {req.get_method()} {url}", flush=True)
    try:
        with DIRECT.open(req, timeout=timeout) as response:
            return json.load(response) if response.status != 202 else None
    except HTTPError as exc:
        detail = exc.read(1500).decode(errors="replace")
        raise RuntimeError(f"{url}: HTTP {exc.code} {detail}") from exc
    except (URLError, TimeoutError) as exc:
        raise RuntimeError(f"{url}: {exc}") from exc


def mcp_status(url, service):
    ids = itertools.count(1)
    headers = {"Accept": "application/json, text/event-stream"}

    def send(method, params=None, *, notification=False):
        message = {"jsonrpc": "2.0", "method": method}
        if not notification:
            message["id"] = next(ids)
        if params is not None:
            message["params"] = params
        response = request_json(url, message, headers=headers, timeout=8)
        if notification:
            return None
        if response.get("id") != message["id"] or "error" in response:
            raise RuntimeError(f"MCP {method}: {response}")
        return response["result"]

    init = send("initialize", {
        "protocolVersion": MCP_VERSION,
        "capabilities": {},
        "clientInfo": {"name": "agent-b", "version": "1.0.0"},
    })
    if init["protocolVersion"] != MCP_VERSION:
        raise RuntimeError(f"Unsupported MCP version: {init['protocolVersion']}")
    headers["MCP-Protocol-Version"] = MCP_VERSION
    send("notifications/initialized", notification=True)
    listed = send("tools/list")
    if TOOL["name"] not in [tool["name"] for tool in listed["tools"]]:
        raise RuntimeError("MCP server did not list get_service_status")
    result = send("tools/call", {"name": TOOL["name"], "arguments": {"service": service}})
    if result.get("isError"):
        raise RuntimeError(f"MCP tool failed: {result['content']}")
    return json.loads(result["content"][0]["text"])


def openai(**params):
    return request_json(OPENAI_URL, {
        "model": os.environ.get("OPENAI_MODEL", "gpt-5-mini"),
        "store": False,
        **params,
    }, headers={"Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}"}, timeout=40)


def output_text(response):
    parts = [
        part["text"]
        for item in response.get("output", []) if item["type"] == "message"
        for part in item["content"] if part["type"] == "output_text"
    ]
    if not parts:
        raise RuntimeError(f"Model returned no text (status={response.get('status')})")
    return "\n".join(parts)


def analyze(question, mcp_url, mode):
    if mode == "mock":
        status = mcp_status(mcp_url, SERVICE)
        return f"{status['service']}: {status['status']}, INC {status['incident']}."

    tool = {
        "type": "function",
        "name": TOOL["name"],
        "description": TOOL["description"],
        "parameters": TOOL["inputSchema"],
        "strict": True,
    }
    history = [{"role": "user", "content": question}]
    first = openai(
        input=history, tools=[tool], tool_choice={"type": "function", "name": TOOL["name"]},
        parallel_tool_calls=False, include=["reasoning.encrypted_content"],
    )
    calls = [item for item in first.get("output", []) if item["type"] == "function_call"]
    if len(calls) != 1 or calls[0]["name"] != TOOL["name"]:
        raise RuntimeError("Expected exactly one get_service_status function call")
    call = calls[0]
    args = json.loads(call["arguments"])
    if args != {"service": SERVICE}:
        raise RuntimeError(f"Unexpected tool arguments: {args}")
    status = mcp_status(mcp_url, args["service"])
    history.extend(first["output"])
    history.append({
        "type": "function_call_output",
        "call_id": call["call_id"],
        "output": json.dumps(status),
    })
    return output_text(openai(
        input=history, tools=[tool], tool_choice="none",
        instructions="Summarize the synthetic tool result briefly in English. Include the service and incident.",
    ))


def agent_card(url):
    return {
        "name": "Agent B",
        "description": "Summarizes the status of a synthetic lab service.",
        "version": "1.0.0",
        "supportedInterfaces": [{"url": url, "protocolBinding": "HTTP+JSON", "protocolVersion": "1.0"}],
        "capabilities": {},
        "defaultInputModes": ["text/plain"],
        "defaultOutputModes": ["text/plain"],
        "skills": [{
            "id": "status", "name": "Service status",
            "description": "Read synthetic service status via MCP.", "tags": ["lab"],
        }],
    }


def run_agent(args):
    base = args.agent_url.rstrip("/")
    card = request_json(f"{base}/.well-known/agent-card.json")
    interface = card["supportedInterfaces"][0]
    if interface["protocolBinding"] != "HTTP+JSON" or interface["url"].rstrip("/") != base:
        raise RuntimeError("Unexpected A2A interface in Agent Card")
    response = request_json(f"{base}/message:send", {"message": {
        "messageId": str(uuid4()), "role": "ROLE_USER", "parts": [{"text": args.question}],
    }}, headers={"Content-Type": A2A_TYPE, "A2A-Version": interface["protocolVersion"]}, timeout=105)
    answer = response["message"]["parts"][0]["text"]
    print(f"Agent B: {answer}")
    if args.mode == "openai":
        answer = output_text(openai(
            input=answer,
            instructions="Rewrite this synthetic service status as one sentence in English, retaining the facts.",
        ))
    print(f"Agent A [{args.mode}]: {answer}")


def mcp_reply(message):
    method = message.get("method")
    if method == "initialize":
        return {"protocolVersion": MCP_VERSION, "capabilities": {"tools": {}},
                "serverInfo": {"name": "lab-tools", "version": "1.0.0"}}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [TOOL]}
    if method == "tools/call":
        params = message.get("params", {})
        if params.get("name") != TOOL["name"]:
            raise ValueError("Unknown tool")
        if params.get("arguments") != {"service": SERVICE}:
            return {"isError": True, "content": [
                {"type": "text", "text": f"Only {SERVICE} is available."},
            ]}
        status = {"service": SERVICE, "status": "degraded", "incident": "LAB-1042"}
        return {"content": [{"type": "text", "text": json.dumps(status)}]}
    raise LookupError("Method not found")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, status, payload=None, content_type="application/json"):
        data = b"" if payload is None else json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        if data:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        args = self.server.lab
        if args.role == "agent-b" and self.path == "/.well-known/agent-card.json":
            self.reply(200, agent_card(args.public_url))
        else:
            self.reply(405 if args.role == "tools" and self.path == "/mcp" else 404)

    def do_POST(self):
        args = self.server.lab
        expected_path = "/mcp" if args.role == "tools" else "/message:send"
        if self.path != expected_path:
            self.close_connection = True
            self.reply(404)
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 65_536:
                raise ValueError("Expected a JSON body of 1–65536 bytes")
            message = json.loads(self.rfile.read(size))
            if not isinstance(message, dict):
                raise ValueError("Expected a JSON object")
        except ValueError as exc:
            self.close_connection = True
            self.reply(400, {"error": str(exc)})
            return

        if args.role == "tools":
            self.handle_mcp(message)
        else:
            self.handle_a2a(message)

    def handle_mcp(self, message):
        method = message.get("method")
        self.log_message("MCP %s", method)
        if message.get("jsonrpc") != "2.0" or not isinstance(method, str):
            self.reply(400, {"jsonrpc": "2.0", "id": message.get("id"),
                             "error": {"code": -32600, "message": "Invalid request"}})
            return
        if "id" not in message:
            self.reply(202)
            return
        response = {"jsonrpc": "2.0", "id": message["id"]}
        try:
            response["result"] = mcp_reply(message)
        except ValueError as exc:
            response["error"] = {"code": -32602, "message": str(exc)}
        except LookupError as exc:
            response["error"] = {"code": -32601, "message": str(exc)}
        self.reply(200, response)

    def handle_a2a(self, message):
        args = self.server.lab
        try:
            question = message["message"]["parts"][0]["text"]
            if not isinstance(question, str) or not question.strip():
                raise ValueError("Expected non-empty text")
        except (KeyError, IndexError, TypeError, ValueError):
            self.reply(400, {"code": "INVALID_ARGUMENT", "message": "Expected a text message"})
            return
        try:
            answer = analyze(question, args.mcp_url, args.mode)
        except (KeyError, TypeError, ValueError, RuntimeError) as exc:
            self.log_error("Upstream: %s", exc)
            self.reply(502, {"code": "UNAVAILABLE", "message": "See Agent B log"})
            return
        self.reply(200, {"message": {
            "messageId": str(uuid4()), "role": "ROLE_AGENT", "parts": [{"text": answer}],
        }}, A2A_TYPE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    roles = parser.add_subparsers(dest="role", required=True)
    tools = roles.add_parser("tools")
    tools.add_argument("--bind", required=True)
    tools.add_argument("--port", type=int, default=8082)
    server = roles.add_parser("agent-b")
    server.add_argument("--bind", required=True)
    server.add_argument("--port", type=int, default=8081)
    server.add_argument("--public-url", required=True)
    server.add_argument("--mcp-url", required=True)
    server.add_argument("--mode", choices=("mock", "openai"), default="mock")
    agent = roles.add_parser("agent-a")
    agent.add_argument("--agent-url", required=True)
    agent.add_argument("--mode", choices=("mock", "openai"), default="mock")
    agent.add_argument("--question", default=f"Check the status of {SERVICE} and include the incident number.")
    args = parser.parse_args()
    if getattr(args, "mode", None) == "openai" and not os.environ.get("OPENAI_API_KEY"):
        parser.error("Set OPENAI_API_KEY for --mode openai")
    if args.role == "agent-a":
        run_agent(args)
    else:
        with ThreadingHTTPServer((args.bind, args.port), Handler) as server:
            server.lab = args
            print(f"{args.role} listening on {args.bind}:{args.port}", flush=True)
            server.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, RuntimeError) as exc:
        sys.exit(str(exc))
    except KeyboardInterrupt:
        pass
