#!/usr/bin/env python3
"""A minimal MCP server for testing lemieux's client.

Deliberately not built on an SDK: the point is to answer exactly what the
specification says, in the shapes a client has to cope with rather than the
ones it would prefer.

    mcp_server.py MODE              speak over stdin/stdout
    mcp_server.py MODE --http PORT  serve the MCP endpoint over HTTP

MODE is one of:

  modern   speaks 2026-07-28: answers server/discover, no handshake
  empty    speaks the modern protocol but offers no tools
  legacy   speaks 2025-11-25: rejects server/discover, wants initialize
  picky    modern, but supports only a version lemieux does not
  broken   emits a line that is not JSON before answering properly (stdio)
  sse      modern, and answers tools/call with an event stream (http)
  mrtr     modern, and asks for input before it will answer a tools/call
  oauth    modern, and is its own OAuth 2.1 authorization server (http)
  oauth_short  as oauth, but issues access tokens that expire immediately
  oauth_cimd   as oauth, but accepts Client ID Metadata Documents and no DCR
  oauth_bare   as oauth, but its challenge names no resource metadata
  duplex   modern, answers requests concurrently on stdio, and offers tools
           that are slow, report progress, notice cancellation, change the
           tool list, ping the client and read the environment; also offers
           prompts and resources
  legacy_duplex  as duplex, but speaks 2025-11-25
"""

import base64
import hashlib
import json
import os
import socketserver
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = sys.argv[1] if len(sys.argv) > 1 else "modern"
OAUTH_MODES = ("oauth", "oauth_short", "oauth_cimd", "oauth_bare")
DUPLEX_MODES = ("duplex", "legacy_duplex")
MODERN_MODES = ("modern", "empty", "picky", "sse", "mrtr", "duplex") + OAUTH_MODES
SESSION_ID = "fixture-session-1"

# What the duplex modes remember: requests the client withdrew, whether the
# tool list has changed, and replies to the requests this server sent.
DUPLEX = {"cancelled": [], "changed": False, "replies": {}, "lock": threading.Lock()}
WRITE_LOCK = threading.Lock()

DUPLEX_TOOLS = [
    {
        "name": "slow",
        "description": "Sleeps, optionally reporting progress, and stops if cancelled.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "seconds": {"type": "number"},
                "progress": {"type": "boolean"},
                "interval": {"type": "number"},
            },
        },
    },
    {
        "name": "fast",
        "description": "Answers at once.",
        "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}},
    },
    {
        "name": "cancelled",
        "description": "Lists the request ids the client withdrew.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "change",
        "description": "Adds a tool and announces that the list changed.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "ping_me",
        "description": "Pings the client and reports whether it answered.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "env",
        "description": "Reports an environment variable, or <unset>.",
        "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}},
    },
    {
        # A name no provider accepts as-is.
        "name": "files.read",
        "description": "Has a dotted name.",
        "inputSchema": {"properties": {"path": {"type": "string"}}},
    },
]

ADDED_TOOL = {
    "name": "added",
    "description": "Appears once the list has changed.",
    "inputSchema": {"type": "object", "properties": {}},
}

PROMPTS = [
    {
        "name": "review",
        "title": "Review",
        "description": "Asks for a review of a file.",
        "arguments": [{"name": "path", "description": "The file.", "required": True}],
    }
]

RESOURCES = [
    {"uri": "fixture://notes", "name": "notes", "mimeType": "text/plain"},
    {"uri": "fixture://logo", "name": "logo", "mimeType": "image/png"},
]

# The authorization server's memory. A dict is enough: one process, one test.
STATE = {"codes": {}, "tokens": {}, "clients": {}, "issued": 0}

TOOLS = [
    {
        "name": "echo",
        "title": "Echo",
        "description": "Echoes the text it is given.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
        "outputSchema": {
            "type": "object",
            "properties": {"echo": {"type": "string"}},
            "required": ["echo"],
        },
        "annotations": {"readOnlyHint": True},
        "_meta": {"publisher": "fixture"},
    },
    {
        "name": "routed",
        "description": "Has a parameter the server wants mirrored into a header.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "region": {"type": "string", "x-mcp-header": "Region"},
                "query": {"type": "string"},
            },
            "required": ["region"],
        },
    },
    {
        # Invalid: a header name with a space in it. A conforming client must
        # drop this tool rather than the whole list.
        "name": "badly_routed",
        "description": "Annotated with an unusable header name.",
        "inputSchema": {
            "type": "object",
            "properties": {"who": {"type": "string", "x-mcp-header": "not a token"}},
        },
    },
    {
        # No inputSchema on purpose: the client should drop this one too.
        "name": "unusable",
        "description": "Has no input schema.",
    },
    {
        # Needs a scope the first authorization does not ask for, so calling it
        # forces the step-up flow.
        "name": "privileged",
        "description": "Needs the write scope.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def ok(request_id, payload, modern=True):
    if modern:
        payload = dict(payload, resultType="complete")
    return {"jsonrpc": "2.0", "id": request_id, "result": payload}


def err(request_id, code, message, data=None):
    body = {"code": code, "message": message}
    if data is not None:
        body["data"] = data
    return {"jsonrpc": "2.0", "id": request_id, "error": body}


def dispatch(request, headers=None):
    """Returns a JSON-RPC response, or None for a notification."""
    headers = headers or {}
    method = request.get("method")
    request_id = request.get("id")
    params = request.get("params") or {}
    modern = MODE in MODERN_MODES

    if method == "server/discover":
        if MODE == "legacy":
            return err(request_id, -32601, "Method not found")
        if MODE == "picky":
            return err(
                request_id,
                -32022,
                "Unsupported protocol version",
                {"supported": ["1900-01-01"], "requested": "2026-07-28"},
            )
        if MODE == "legacy_duplex":
            return err(request_id, -32601, "Method not found")
        capabilities = {"tools": {}}
        if MODE in DUPLEX_MODES:
            capabilities = {"tools": {"listChanged": True}, "prompts": {}, "resources": {}}
        return ok(
            request_id,
            {
                "supportedVersions": ["2026-07-28"],
                "capabilities": capabilities,
                "_meta": {
                    "io.modelcontextprotocol/serverInfo": {
                        "name": "fixture",
                        "version": "1.0.0",
                    }
                },
            },
        )

    if method == "initialize":
        if modern:
            return err(request_id, -32601, "this server is modern; use per-request _meta")
        capabilities = {"tools": {}}
        if MODE in DUPLEX_MODES:
            capabilities = {"tools": {"listChanged": True}, "prompts": {}, "resources": {}}
        return ok(
            request_id,
            {
                "protocolVersion": "2025-11-25",
                "capabilities": capabilities,
                "serverInfo": {"name": "fixture", "version": "1.0.0"},
            },
            modern=False,
        )

    if method == "notifications/initialized":
        return None

    if method == "notifications/cancelled":
        with DUPLEX["lock"]:
            DUPLEX["cancelled"].append(params.get("requestId"))
        return None

    if modern:
        # Every modern request must say which version it is using, in the body
        # and — over HTTP — in a header that matches it.
        version = params.get("_meta", {}).get("io.modelcontextprotocol/protocolVersion")
        if not version:
            return err(request_id, -32022, "Unsupported protocol version",
                       {"supported": ["2026-07-28"]})
        header_version = headers.get("mcp-protocol-version")
        if headers and header_version != version:
            return err(request_id, -32020,
                       "Header mismatch: MCP-Protocol-Version %r does not match body %r"
                       % (header_version, version))
        if headers and headers.get("mcp-method") != method:
            return err(request_id, -32020, "Header mismatch: Mcp-Method")

    if method == "tools/list":
        if MODE in DUPLEX_MODES:
            tools = DUPLEX_TOOLS + ([ADDED_TOOL] if DUPLEX["changed"] else [])
            return ok(request_id, {"tools": tools}, modern=modern)
        if MODE == "sse" and STATE.get("changed"):
            return ok(request_id, {"tools": TOOLS + [ADDED_TOOL]}, modern=modern)
        return ok(request_id, {"tools": [] if MODE == "empty" else TOOLS}, modern=modern)

    if method == "prompts/list":
        return ok(request_id, {"prompts": PROMPTS}, modern=modern)

    if method == "prompts/get":
        path = (params.get("arguments") or {}).get("path", "?")
        return ok(
            request_id,
            {
                "description": "A review request.",
                "messages": [
                    {"role": "user", "content": {"type": "text", "text": "Please review " + path}},
                    {"role": "user", "content": {"type": "image", "data": "", "mimeType": "image/png"}},
                ],
            },
            modern=modern,
        )

    if method == "resources/list":
        return ok(request_id, {"resources": RESOURCES}, modern=modern)

    if method == "resources/read":
        uri = params.get("uri")
        if uri == "fixture://notes":
            contents = [{"uri": uri, "mimeType": "text/plain", "text": "remember the milk"}]
        else:
            contents = [{"uri": uri, "mimeType": "image/png", "blob": "iVBORw0KGgo="}]
        return ok(request_id, {"contents": contents}, modern=modern)

    if method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") or {}

        if headers and modern and headers.get("mcp-name") != name:
            return err(request_id, -32020, "Header mismatch: Mcp-Name")

        if MODE in DUPLEX_MODES:
            return duplex_tool(request_id, name, arguments, params, modern)

        if MODE == "sse" and name == "change":
            STATE["changed"] = True
            return ok(request_id, {"content": [{"type": "text", "text": "changed"}]}, modern=modern)

        if MODE == "mrtr" and name == "echo":
            responses = params.get("inputResponses") or {}
            reply = responses.get("who")

            if not reply:
                return {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "resultType": "input_required",
                        "inputRequests": {
                            "who": {
                                "method": "elicitation/create",
                                "params": {
                                    "mode": "form",
                                    "message": "who is asking?",
                                    "requestedSchema": {
                                        "type": "object",
                                        "properties": {"name": {"type": "string"}},
                                        "required": ["name"],
                                    },
                                },
                            }
                        },
                        "requestState": "opaque-state",
                    },
                }

            if params.get("requestState") != "opaque-state":
                return err(request_id, -32602, "the client did not echo requestState back")

            if reply.get("action") != "accept":
                return ok(request_id,
                          {"content": [{"type": "text", "text": "declined"}], "isError": True},
                          modern=modern)

            who = (reply.get("content") or {}).get("name")
            return ok(request_id,
                      {"content": [{"type": "text", "text": "hello " + str(who)}]},
                      modern=modern)

        if name == "echo":
            echoed = "echo: " + str(arguments.get("text"))
            return ok(
                request_id,
                {
                    "content": [{"type": "text", "text": echoed}],
                    "structuredContent": {"echo": echoed},
                },
                modern=modern,
            )

        if name == "routed":
            # Reports back what the client mirrored, so the test can see it.
            return ok(
                request_id,
                {"content": [{"type": "text",
                              "text": "region header: " + str(headers.get("mcp-param-region"))}]},
                modern=modern,
            )

        if name == "privileged":
            return ok(
                request_id,
                {"content": [{"type": "text", "text": "you may write"}]},
                modern=modern,
            )

        if name == "explode":
            return ok(
                request_id,
                {"content": [{"type": "text", "text": "that did not work"}], "isError": True},
                modern=modern,
            )

        return err(request_id, -32602, "Unknown tool: " + str(name))

    return err(request_id, -32601, "Method not found: " + str(method))


def text(request_id, value, modern):
    return ok(request_id, {"content": [{"type": "text", "text": value}]}, modern=modern)


def duplex_tool(request_id, name, arguments, params, modern):
    token = (params.get("_meta") or {}).get("progressToken")

    if name == "slow":
        seconds = float(arguments.get("seconds", 1))
        interval = float(arguments.get("interval", 0.05))
        report = bool(arguments.get("progress"))
        waited = 0.0
        while waited < seconds:
            with DUPLEX["lock"]:
                if request_id in DUPLEX["cancelled"]:
                    # A withdrawn request gets no answer at all.
                    return None
            time.sleep(interval)
            waited += interval
            if report and token is not None:
                write({"jsonrpc": "2.0", "method": "notifications/progress",
                       "params": {"progressToken": token, "progress": waited, "total": seconds}})
        return text(request_id, "slept %s" % seconds, modern)

    if name == "fast":
        return text(request_id, "fast: " + str(arguments.get("text")), modern)

    if name == "cancelled":
        with DUPLEX["lock"]:
            ids = list(DUPLEX["cancelled"])
        return text(request_id, json.dumps(ids), modern)

    if name == "change":
        DUPLEX["changed"] = True
        write({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
        return text(request_id, "changed", modern)

    if name == "ping_me":
        key = "srv-%s" % request_id
        event = threading.Event()
        with DUPLEX["lock"]:
            DUPLEX["replies"][key] = event
        write({"jsonrpc": "2.0", "id": key, "method": "ping"})
        return text(request_id, "pong received" if event.wait(5) else "no pong", modern)

    if name == "env":
        value = os.environ.get(str(arguments.get("name", "")))
        return text(request_id, value if value is not None else "<unset>", modern)

    if name in ("files.read", "added"):
        return text(request_id, name + " ran", modern)

    return err(request_id, -32602, "Unknown tool: " + str(name))


# --------------------------------------------------------------------------
# stdio
# --------------------------------------------------------------------------


def write(message):
    # A client that has gone away closes the pipe; that ends this server,
    # quietly, rather than with a traceback in somebody's test output.
    with WRITE_LOCK:
        try:
            sys.stdout.write(json.dumps(message) + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            os._exit(0)


def answer(request):
    response = dispatch(request)
    if response is not None:
        write(response)


def serve_stdio():
    if MODE == "broken":
        sys.stdout.write("this is not json\n")
        sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue

        # A reply to a request this server sent, such as its ping.
        if "method" not in request and "id" in request:
            with DUPLEX["lock"]:
                event = DUPLEX["replies"].pop(request.get("id"), None)
            if event is not None:
                event.set()
            continue

        if MODE in DUPLEX_MODES:
            threading.Thread(target=answer, args=(request,), daemon=True).start()
        else:
            answer(request)


# --------------------------------------------------------------------------
# OAuth 2.1, for the oauth modes
#
# Deliberately strict about the things a client is *required* to send, so that
# a client which forgets one fails here rather than silently against a real
# server months later: PKCE with S256, the resource parameter on both requests,
# state, and a redirect_uri that matches the one the code was authorized for.
# --------------------------------------------------------------------------


def base_url(handler):
    return "http://" + handler.headers.get("Host", "127.0.0.1")


def issue(prefix):
    """A name unique to this server, not only to this counter.

    The port is in it so that two fixtures running side by side cannot mint
    identical-looking tokens — otherwise a test asserting that one server's
    token never reaches another passes by coincidence.
    """
    STATE["issued"] += 1
    port = sys.argv[sys.argv.index("--http") + 1] if "--http" in sys.argv else "0"
    return "%s-%s-%d" % (prefix, port, STATE["issued"])


def token_lifetime():
    # One second: long enough for the retry that immediately follows the
    # exchange, short enough that the next call is refused and has to refresh.
    # It is also well inside the client's expiry skew, so a client reading this
    # token from a store treats it as spent without asking.
    return 1 if MODE == "oauth_short" else 3600


def scopes_of(token):
    return (STATE["tokens"].get(token) or {}).get("scope", "").split()


def authorize(handler, query):
    """The authorization endpoint. No user to ask, so consent is automatic."""
    required = ["client_id", "redirect_uri", "state", "code_challenge", "resource"]
    missing = [name for name in required if not query.get(name)]
    if missing:
        return handler._send(400, json.dumps({"error": "invalid_request", "missing": missing}))

    if query.get("code_challenge_method", [""])[0] != "S256":
        return handler._send(400, json.dumps({"error": "invalid_request",
                                              "error_description": "S256 only"}))

    code = issue("code")
    STATE["codes"][code] = {
        "challenge": query["code_challenge"][0],
        "redirect_uri": query["redirect_uri"][0],
        "resource": query["resource"][0],
        "scope": query.get("scope", [""])[0],
        "client_id": query["client_id"][0],
    }

    location = query["redirect_uri"][0] + "?" + urllib.parse.urlencode({
        "code": code,
        "state": query["state"][0],
        "iss": base_url(handler),
    })

    handler.send_response(302)
    handler.send_header("Location", location)
    handler.send_header("Content-Length", "0")
    handler.end_headers()


def token_endpoint(handler, form):
    grant = form.get("grant_type", [""])[0]

    if grant == "authorization_code":
        record = STATE["codes"].pop(form.get("code", [""])[0], None)
        if not record:
            return handler._send(400, json.dumps({"error": "invalid_grant"}))

        verifier = form.get("code_verifier", [""])[0]
        digest = hashlib.sha256(verifier.encode()).digest()
        if base64.urlsafe_b64encode(digest).rstrip(b"=").decode() != record["challenge"]:
            return handler._send(400, json.dumps({"error": "invalid_grant",
                                                  "error_description": "PKCE verification failed"}))

        if form.get("redirect_uri", [""])[0] != record["redirect_uri"]:
            return handler._send(400, json.dumps({"error": "invalid_grant",
                                                  "error_description": "redirect_uri mismatch"}))

        if form.get("resource", [""])[0] != record["resource"]:
            return handler._send(400, json.dumps({"error": "invalid_target"}))

        return mint(handler, record["resource"], record["scope"])

    if grant == "refresh_token":
        record = STATE["tokens"].get(form.get("refresh_token", [""])[0])
        if not record:
            return handler._send(400, json.dumps({"error": "invalid_grant"}))

        return mint(handler, record["resource"], record["scope"])

    handler._send(400, json.dumps({"error": "unsupported_grant_type"}))


def mint(handler, resource, scope):
    access, refresh = issue("at"), issue("rt")
    record = {"resource": resource, "scope": scope, "expires": time.time() + token_lifetime()}

    STATE["tokens"][access] = record
    STATE["tokens"][refresh] = record

    handler._send(200, json.dumps({
        "access_token": access,
        "refresh_token": refresh,
        "token_type": "Bearer",
        "expires_in": token_lifetime(),
        "scope": scope,
    }))


def refuse(handler, resource_metadata):
    """The 401 that starts everything."""
    challenge = 'Bearer realm="OAuth", error="invalid_token"'
    if MODE != "oauth_bare":
        challenge += ', resource_metadata="%s", scope="read"' % resource_metadata

    handler._send(401, json.dumps({"error": "invalid_token"}),
                  extra={"WWW-Authenticate": challenge})


def authorized(handler, request):
    """None when the request may proceed, or a response that has been sent."""
    header = handler.headers.get("Authorization", "")
    token = header[7:] if header.lower().startswith("bearer ") else None
    resource = base_url(handler) + "/mcp"
    metadata = base_url(handler) + "/.well-known/oauth-protected-resource/mcp"

    record = STATE["tokens"].get(token) if token else None

    if not record or record["expires"] < time.time():
        return refuse(handler, metadata) or True

    # The heart of resource binding: a token minted for somewhere else is no
    # better than no token at all.
    if record["resource"] != resource:
        return refuse(handler, metadata) or True

    name = ((request.get("params") or {}).get("name"))
    if request.get("method") == "tools/call" and name == "privileged":
        if "write" not in record["scope"].split():
            handler._send(403, json.dumps({"error": "insufficient_scope"}), extra={
                "WWW-Authenticate":
                    'Bearer error="insufficient_scope", scope="write", resource_metadata="%s"'
                    % metadata,
            })
            return True

    return False


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # noqa: D102 - quiet
        pass

    def _send(self, status, body, content_type="application/json", extra=None):
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)

        if MODE in OAUTH_MODES:
            base = base_url(self)

            if parsed.path == "/.well-known/oauth-protected-resource/mcp":
                return self._send(200, json.dumps({
                    "resource": base + "/mcp",
                    "authorization_servers": [base],
                    "scopes_supported": ["read"],
                }))

            if parsed.path == "/.well-known/oauth-authorization-server":
                metadata = {
                    "issuer": base,
                    "authorization_endpoint": base + "/authorize",
                    "token_endpoint": base + "/token",
                    "code_challenge_methods_supported": ["S256"],
                    "scopes_supported": ["read", "write"],
                    "grant_types_supported": ["authorization_code", "refresh_token"],
                }
                if MODE == "oauth_cimd":
                    metadata["client_id_metadata_document_supported"] = True
                else:
                    metadata["registration_endpoint"] = base + "/register"

                return self._send(200, json.dumps(metadata))

            if parsed.path == "/authorize":
                return authorize(self, urllib.parse.parse_qs(parsed.query))

        # This revision removed the GET stream entirely.
        self._send(405, json.dumps({"error": "method not allowed"}))

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode("utf-8")
        headers = {key.lower(): value for key, value in self.headers.items()}
        path = urllib.parse.urlparse(self.path).path

        # Explicit fixture control: exercise a server-side 401 mid-session
        # without waiting for wall-clock token expiry.
        if MODE in OAUTH_MODES and path == "/_fixture/expire":
            access = json.loads(raw)["access_token"]
            STATE["tokens"][access]["expires"] = 0
            return self._send(200, json.dumps({"expired": access}))

        if MODE in OAUTH_MODES and path == "/token":
            return token_endpoint(self, urllib.parse.parse_qs(raw))

        if MODE in OAUTH_MODES and path == "/register":
            body = json.loads(raw)
            client_id = issue("client")
            STATE["clients"][client_id] = body
            return self._send(201, json.dumps({
                "client_id": client_id,
                "redirect_uris": body.get("redirect_uris", []),
            }))

        try:
            request = json.loads(raw)
        except json.JSONDecodeError:
            self._send(400, json.dumps({"error": "not json"}))
            return

        if MODE in OAUTH_MODES and authorized(self, request):
            return

        legacy = MODE == "legacy"

        # A legacy server insists on its session id after initialize.
        if legacy and request.get("method") not in ("initialize", "notifications/initialized"):
            if headers.get("mcp-session-id") != SESSION_ID:
                self._send(400, "")
                return

        response = dispatch(request, headers)

        if response is None:
            self._send(202, "")
            return

        extra = {}
        if legacy and request.get("method") == "initialize":
            extra["Mcp-Session-Id"] = SESSION_ID

        error = response.get("error") or {}
        # Modern errors that the specification says travel as 400.
        status = 400 if error.get("code") in (-32022, -32020) else 200

        if MODE == "sse" and request.get("method") == "tools/call":
            announced = ""
            if (request.get("params") or {}).get("name") == "change":
                announced = 'data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n\n'
            stream = (
                ": keep-alive\n\n"
                'data: {"jsonrpc":"2.0","method":"notifications/progress",'
                '"params":{"progress":1}}\n\n'
                + announced
                + "data: " + json.dumps(response) + "\n\n"
            )
            self._send(200, stream, content_type="text/event-stream")
            return

        self._send(status, json.dumps(response), extra=extra)


class FixtureHTTPServer(ThreadingHTTPServer):
    # HTTPServer.server_bind names the bound address with socket.getfqdn, a
    # reverse DNS lookup that other projects have seen stall for half a
    # minute on GitHub's macOS runners. That is the likely reason every HTTP
    # fixture test failed on the nightly macOS job with "the fixture never
    # listened" (29 a night, the stdio fixtures passing beside them), while
    # the fixture answers in 50 ms on a laptop and the tests wait five seconds
    # for "ready". Unconfirmed until a nightly run passes with this in place;
    # nothing here uses the name either way.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def serve_http(port):
    server = FixtureHTTPServer(("127.0.0.1", port), Handler)
    print("ready", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    if "--http" in sys.argv:
        serve_http(int(sys.argv[sys.argv.index("--http") + 1]))
    else:
        serve_stdio()
