#!/usr/bin/env python3
"""Which MCP era does a real client adopt against this store? Run INSIDE a client venv.

  U=https://<store>/skillhub K=<MCP_KEY_NN> /opt/hermes/.venv/bin/python utils/probe-mcp-era.py

utils/test-mcp-protocol.py proves the server answers both eras. This proves the other
half: that the client's own SDK, in its default 'auto' mode, actually adopts the modern
one. The SDK probes server/discover, validates the result with pydantic, and falls back
to the legacy initialize handshake on ANY disagreement -- silently, with fifteen tools
still working. So a server can look fine in every log while every client is on the old
path. Measured 2026-09-14: before server/discover existed here that is exactly what
happened.

Prints which of session.discover_result / session.initialize_result was set, and the
negotiated version. Needs the `mcp` SDK, so it runs where a client runs, not on the
host. No key on the command line: it comes from the environment.
"""
import asyncio, os, importlib
import mcp.client.client as C
def innermost(e):
    while getattr(e,"exceptions",None): e=e.exceptions[0]
    return e
async def main():
    url=os.environ["U"]; key=os.environ["K"]
    hx=None
    for m in ("httpx2","httpx"):
        try: hx=importlib.import_module(m); print("http lib:", m); break
        except ImportError: pass
    http=hx.AsyncClient(headers={"apikey":key,"User-Agent":"skillhub-era-probe/1"}, timeout=60)
    transport=C.streamable_http_client(url, http_client=http)
    try:
        async with C.Client(transport, mode="auto") as s:
            sess=getattr(s,"session",s)
            dr=getattr(sess,"discover_result",None); ir=getattr(sess,"initialize_result",None)
            nv=None
            for a in ("_negotiated_version","negotiated_version","protocol_version"):
                v=getattr(sess,a,None)
                if v is not None: nv=v() if callable(v) else v; break
            print("discover_result set  :", dr is not None)
            print("initialize_result set:", ir is not None)
            print("negotiated version   :", nv)
            if dr is not None: print("server advertised    :", getattr(dr,"supported_versions",None))
            tl=await (s.list_tools() if hasattr(s,"list_tools") else sess.list_tools())
            print("tools via SDK        :", len(getattr(tl,"tools",tl)))
    except BaseException as e:
        ie=innermost(e); print("FAILED:", type(ie).__name__, str(ie)[:300]); raise SystemExit(1)
asyncio.run(main())
