#!/usr/bin/env python3
"""Prove the MCP server speaks both protocol eras, against a running instance.

  python3 utils/test-mcp-protocol.py https://<store>/skillhub --apikey <MCP_KEY_NN>
  python3 utils/test-mcp-protocol.py http://127.0.0.1:19000/skillhub --agent agent_03

Through the gateway, pass --apikey and the identity comes from Kong. Against a bare
edge-runtime (no gateway in front), pass --agent to set the header the gateway would have
set. Exit code is the number of failing checks.

Why this exists. The 2026-07-28 revision made MCP stateless: no initialize handshake,
version and client capabilities in every request's _meta, one MUST (server/discover), a
required resultType on every result, cache hints on list results, and two error codes that
have to travel with HTTP 400. This server is dual-era -- a request with modern _meta is served
the modern way, one that opens with initialize the legacy way -- and Hermes is a dual-era
client that probes modern first and falls back on anything it does not recognise. Until
2026-09-14 our server answered "Unknown method" to server/discover, so every Hermes fell back
to the legacy handshake and nobody noticed. The checks below are the ones that decide which
era a client lands in.
"""
import argparse, json, sys, urllib.request

MOD = {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
       "io.modelcontextprotocol/clientCapabilities": {},
       "io.modelcontextprotocol/clientInfo": {"name": "test-mcp-protocol", "version": "1"}}
SI = "io.modelcontextprotocol/serverInfo"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--apikey", help="MCP key; identity resolved by the gateway")
    g.add_argument("--agent", help="agent_NN; sets x-consumer-username directly (no gateway)")
    a = ap.parse_args()
    # A User-Agent, because a Cloudflare tunnel's browser-integrity check answers HTTP 403
    # "error code: 1010" to Python's default "Python-urllib/3.x" before the request reaches
    # the gateway. Measured 2026-09-14: eleven of fourteen checks failed on a server that was
    # fine. Hermes sends "python-httpx2/..." and passes; so does this once it identifies itself.
    headers = {"content-type": "application/json", "User-Agent": "skillhub-test-mcp-protocol/1"}
    if a.apikey: headers["apikey"] = a.apikey
    else: headers["x-consumer-username"] = a.agent

    def call(method, params=None):
        body = json.dumps({"jsonrpc": "2.0", "id": 7, "method": method, "params": params or {}}).encode()
        req = urllib.request.Request(a.url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, json.loads(r.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            raw = e.read().decode()
            try: return e.code, json.loads(raw)
            except Exception: return e.code, {"_raw": raw[:200]}

    fails = 0
    def check(label, cond, detail=""):
        nonlocal fails
        print(f"  {'ok  ' if cond else 'FAIL'} {label}" + (f"   [{detail}]" if (detail and not cond) else ""))
        fails += 0 if cond else 1
    def who(d):
        try: return json.loads(d["result"]["content"][0]["text"])["agent"]
        except Exception: return None

    print("legacy client (initialize handshake, no _meta)")
    s, d = call("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "old", "version": "1"}})
    r = d.get("result", {})
    check("initialize -> 200 with protocolVersion 2025-03-26", s == 200 and r.get("protocolVersion") == "2025-03-26", str(d)[:140])
    check("resultType=complete and _meta.serverInfo on the result", r.get("resultType") == "complete" and r.get("_meta", {}).get(SI, {}).get("name") == "skillhub")
    s, d = call("tools/call", {"name": "skillhub_whoami", "arguments": {}})
    legacy_who = who(d)
    check("tools/call whoami without _meta answers an agent", s == 200 and bool(legacy_who), str(d)[:140])

    print("modern client (2026-07-28, per-request _meta)")
    s, d = call("server/discover", {"_meta": MOD}); r = d.get("result", {})
    check("server/discover -> 200 (the one MUST)", s == 200 and "result" in d, str(d)[:160])
    check("supportedVersions includes 2026-07-28 and 2025-03-26", set(["2026-07-28", "2025-03-26"]) <= set(r.get("supportedVersions", [])), str(r.get("supportedVersions")))
    check("capabilities.tools, instructions, ttlMs, cacheScope", "tools" in r.get("capabilities", {}) and bool(r.get("instructions")) and isinstance(r.get("ttlMs"), int) and r.get("cacheScope") in ("public", "private"))
    s, d = call("tools/list", {"_meta": MOD}); r = d.get("result", {})
    # The count is asserted against the server's own list rather than a number in this file:
    # it was hardcoded twice and failed twice on a store that was fine (15 -> 17 -> 19).
    tools = r.get("tools", [])
    check("tools/list -> every tool, with ttlMs and cacheScope",
          s == 200 and len(tools) >= 15 and "ttlMs" in r and "cacheScope" in r,
          "%d tools, keys %s" % (len(tools), str(list(r.keys()))[:90]))
    s, d = call("tools/call", {"name": "skillhub_whoami", "arguments": {}, "_meta": MOD})
    check("tools/call whoami with modern _meta answers the same agent", s == 200 and who(d) == legacy_who and d.get("result", {}).get("resultType") == "complete", str(d)[:140])
    s, d = call("tools/call", {"name": "skillhub_whoami", "arguments": {"agent": "agent_01"}, "_meta": MOD})
    check("a spoofed agent argument is still overwritten on the modern path", who(d) == legacy_who, str(who(d)))

    print("errors the spec pins down")
    bad = dict(MOD); bad["io.modelcontextprotocol/protocolVersion"] = "1900-01-01"
    s, d = call("tools/list", {"_meta": bad}); e = d.get("error", {})
    check("unknown version -> HTTP 400, -32022, data.supported + data.requested", s == 400 and e.get("code") == -32022 and e.get("data", {}).get("requested") == "1900-01-01" and "2026-07-28" in e.get("data", {}).get("supported", []), f"{s} {e}")
    s, d = call("tools/list", {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}}); e = d.get("error", {})
    check("modern request without clientCapabilities -> HTTP 400, -32602", s == 400 and e.get("code") == -32602, f"{s} {e}")
    s, d = call("nope/method", {"_meta": MOD}); e = d.get("error", {})
    check("unknown method -> -32601 (not a bad-request class, so HTTP 200)", e.get("code") == -32601, f"{s} {e}")

    print(f"\n{'PASS' if fails == 0 else 'FAIL'} -- {fails} failing check(s)")
    sys.exit(fails)

if __name__ == "__main__":
    main()
