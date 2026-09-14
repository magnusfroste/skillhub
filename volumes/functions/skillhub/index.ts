// MCP server for the shared data store.
//
// Why it exists: Supabase's own MCP server has eleven fixed tools and cannot be extended
// without forking Studio.
//
// Measured in Hermes 2026-09-10, and it governs how the text below is written: with 44 tools
// Hermes puts MCP tools in a DEFERRED pool. The agent sees a catalogue of names and a
// TRUNCATED description (~60 characters) and has to load the tool to see the full schema.
// The server's `instructions` from initialize do not reach the agent's context at all.
//
// So the tool name and the first sentence are all that is guaranteed. The first clause has
// to carry the whole message -- the rest is read only once the agent has already chosen the
// tool. Two of today's failures were first clauses that were true when written and had
// quietly stopped being true.
//
// This is the ONLY door for an agent key. Until 2026-09-12 agents also had Supabase's own
// MCP server with execute_sql, and this file used to say so. That door now answers 403 for
// anything but the admin key, because a write through it took the author from the row's own
// columns -- an honour system, demonstrated broken on 2026-09-11.
//
// Identity: Kong's key-auth sets X-Consumer-Username on the way up, i.e. the agent_NN bound
// to the API key in volumes/api/kong.yml. Every writing tool takes it from there and
// overwrites whatever the agent supplied. Verified 2026-09-14 against a forged argument AND
// a forged header at the same time: both were overwritten and the row landed under the
// calling key.
//
// No external dependencies: everything goes through PostgREST with the service key, which is
// already in the environment. No deno.land fetch, nothing to keep up to date.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "http://api-gw:8000";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const PROTOCOL = "2025-03-26";

type Tool = {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  rpc: string;
  /** Passes the verified agent as an argument. Without one the call is refused. */
  needsAgent?: boolean;
  /** Passes the agent when there is one, but does not refuse without it. For read
   *  tools whose RPC filters on ownership: with no identity they see only public
   *  content, so less and never more. Refusing instead would make reading impossible
   *  whenever the header is absent, which is a worse outcome than a narrower answer. */
  passAgent?: boolean;
  /** The answer is already text (the daily report, say). Pass it through unchanged. */
  raw?: boolean;
};

const obj = (props: Record<string, unknown>, required: string[] = []) => ({
  type: "object",
  properties: props,
  required,
  additionalProperties: false,
});
const str = (description: string) => ({ type: "string", description });
const int = (description: string, def: number) => ({ type: "integer", description, default: def });

const TOOLS: Tool[] = [
  {
    name: "skillhub_overview",
    description:
      "Start here in a new session: the state of the shared store. Counts of tables and skills, active agents, every table with its comment and row count, where data came from and how fresh it is, and how much is waiting to be cleaned up.",
    inputSchema: obj({}),
    rpc: "skillhub_overview",
  },
  {
    name: "skillhub_search",
    description:
      "Search here BEFORE creating anything new, and before you ANSWER a question from the data. Keywords over skills, notes, documents and the table AND COLUMN comments -- the comments are where 'how this data has to be read' is written down. If nothing matches it falls back to meaning by itself, which also crosses languages. If something similar exists, extend it instead of adding a second variant.",
    inputSchema: obj(
      { query: str("Keywords; several words are treated as OR"), max_hits: int("Maximum hits", 10) },
      ["query"],
    ),
    rpc: "skillhub_search",
    passAgent: true,
  },
  {
    name: "skillhub_rules",
    description:
      "Read the rules before you write anything the first time. The placement rule decides whether something becomes a table, a note or a skill. Also lists the house standards for different kinds of work, and what the activity log does not prove.",
    inputSchema: obj({}),
    rpc: "skillhub_rules",
  },
  {
    name: "skillhub_read",
    description:
      "Fetch one object in FULL, never a fragment. Search tells you which object; this gives you all of it, so you never answer from an excerpt without its context. Kind is skill, note, document or table.",
    inputSchema: obj(
      {
        kind: str("skill, note, document or table"),
        id: str("Slug for a skill, uuid for a note or document, table name for a table"),
      },
      ["kind", "id"],
    ),
    rpc: "skillhub_read",
    passAgent: true,
  },
  {
    name: "skillhub_similar",
    description:
      "Search by MEANING when keyword search finds nothing but the subject should exist. Embeds your question and compares it with everything indexed. Returns which objects are relevant; read them with skillhub_read.",
    inputSchema: obj(
      { query: str("Free text; a sentence works better than a single word"), max_hits: int("Maximum hits", 5) },
      ["query"],
    ),
    rpc: "__semantic__",
  },
  {
    name: "skillhub_activity",
    description:
      "What other agents did recently, collapsed per minute so a bulk load does not drown the rest. Use it to see whether someone is already working on the same thing and what changed since last time.",
    inputSchema: obj({ max_rows: int("Number of rows", 20) }),
    rpc: "skillhub_activity",
  },
  {
    name: "skillhub_query",
    description:
      "COUNT, SUM, AVERAGE or GROUP BY over one table — use this to answer a question from business data. It takes no SQL: name the table, the columns (a column name, count(*), or count/sum/avg/min/max of one column), filters as [column, operator, value], and what to group by. Read-only, row-capped, and the ownership filter is applied for you. Check the column comments with skillhub_read kind=table first: they say which values have to be excluded, and a total that includes them is wrong by a wide margin.",
    inputSchema: obj({
      table_name: str("The table in public, e.g. ncr."),
      columns: { type: "array", items: { type: "string" },
        description: "e.g. [\"status\",\"count(*)\"] or [\"sum(defect_count)\"]. Defaults to count(*)." },
      filters: { type: "array", items: { type: "array" },
        description: "e.g. [[\"defect_count\",\"not in\",[999999,333]],[\"status\",\"=\",\"Completed\"]]. Operators: = <> < <= > >= in, not in, like, ilike, is null, is not null. To compare two COLUMNS, give the value as an object: [\"closed_date\",\">\",{\"column\":\"planned_ready_date\"}] -- that is how you answer \"how many are overdue\"." },
      group_by: { type: "array", items: { type: "string" }, description: "Columns to group by." },
      order_by: str("One column or aggregate name, optionally asc or desc. e.g. \"count desc\"."),
      row_limit: int("Rows to return, at most 1000.", 100),
      bucket: { type: "object",
        description: "Group by time period, e.g. {\"column\":\"reg_date\",\"unit\":\"month\"}. Units: day, week, month, quarter, year. Adds a `period` column you can order by. This is how you answer \"how has it developed over time\"." },
    }, ["table_name"]),
    rpc: "skillhub_query",
    needsAgent: true,
  },
  {
    name: "skillhub_write_note",
    description:
      "Save free text: an observation, an investigation, how something works. The default choice when it is not the same shape over and over (that is a table) and not instructions others should follow (that is a skill). Ownership is filled in from your key; you cannot set it.",
    inputSchema: obj(
      {
        title: str("Short heading"),
        content: str("Body text, markdown allowed"),
        tags: { type: "array", items: { type: "string" }, description: "Free tags for search" },
        private: { type: "boolean", description: "True only when the user explicitly asked for it", default: false },
      },
      ["title", "content"],
    ),
    rpc: "skillhub_write_note",
    needsAgent: true,
  },
  {
    name: "skillhub_publish_skill",
    description:
      "Publish instructions other agents should follow, after searching -- it is refused unless you ran skillhub_search first, because the library must not fill up with second versions of the same thing. Use it when you have found a way of working that will be needed again. At least 200 characters: describe the procedure, not just the heading. You cannot publish over an existing version, yours or a colleague's; publish a HIGHER version, which supersedes the older one and is what readers get from then on.",
    inputSchema: obj(
      {
        slug: str("Short name, lowercase with hyphens, e.g. loading-from-source-system"),
        name: str("Readable name"),
        content: str("The whole instruction in markdown, preferably with frontmatter"),
        description: str("One sentence on when to use it"),
        tags: { type: "array", items: { type: "string" }, description: "Tag it house-standard if it describes how a kind of work is done here" },
        version: str("Version, default 1.0.0"),
      },
      ["slug", "name", "content"],
    ),
    rpc: "skillhub_publish_skill",
    needsAgent: true,
  },
  {
    name: "skillhub_request_structure",
    description:
      "Ask for somewhere to put structured data. Two cases, and the second is the one people miss: no table fits at all, OR a table fits but is MISSING A FIELD you need -- ask for the column, do not drop the field and do not retire the source that still holds it. Use it the moment you notice you are about to lose something because there is nowhere to put it: say what the data is for, list the fields, and attach the rows you are holding so they survive the wait. You cannot create tables yourself -- that keeps the data model deliberate -- but the caretaker sees every request and is the only one who can tell that two people asked for the same thing. It answers with existing tables and other open requests that look related: read them, because a column on something that exists beats a table beside it.",
    inputSchema: obj({
      purpose: str("What the data is for, in a sentence. The decision between a column and a new table is made on this, not on the field names."),
      fields: { type: "array", items: { type: "string" },
        description: "The fields you need, e.g. [\"supplier\",\"audit_date\",\"score\",\"deviations\",\"status\",\"auditor\"]." },
      sample_rows: { type: "array", items: { type: "object" },
        description: "The rows you are holding, as objects. At most 200 -- more than that is a delivery for the caretaker." },
      suggested_name: str("A name you would give the table, if you have one in mind."),
    }, ["purpose", "fields"]),
    rpc: "skillhub_request_structure",
    needsAgent: true,
  },
  {
    name: "skillhub_add_rows",
    description:
      "Add rows to a table that already exists — this is how you fill in a structure somebody else defined, the way you would add items to a list rather than inventing a new file type. Give rows as objects with the same fields in each. Ownership and timestamps come from your key, never from the rows, so everything you add is attributable to you and appears in the flow view. Creating a NEW table is the caretaker's job: describe what you need and ask. At most 500 rows per call.",
    inputSchema: obj({
      table_name: str("An existing table in public. skillhub_overview lists them."),
      rows: { type: "array", items: { type: "object" },
        description: "Objects with identical fields, e.g. [{\"name\":\"ACME\",\"city\":\"Malmo\"}]. Leave out owner, created_by, updated_by and the timestamps -- those come from your key." },
      visibility: str("public (default) or private. Private rows are never indexed, so nobody finds them by meaning."),
    }, ["table_name", "rows"]),
    rpc: "skillhub_add_rows",
    needsAgent: true,
  },
  {
    name: "skillhub_register_document",
    description:
      // The first clause is the whole message: with many tools Hermes shows only the name and
      // roughly 60 characters. This description used to open by saying a human uploads the
      // content, and on 2026-09-13 an agent holding a quality manual it could read perfectly
      // registered the file, reported that a person had to upload it, and stopped -- three
      // times, once after the user said they could not upload anything.
      "Catalogue a file -- and then put its CONTENT in yourself, because registering it shares nothing. Nothing here reads inside a file and no later step will, so a registered document is findable by name and cannot answer one question about what it says. Publish each rule or procedure it contains as a skill, keeping the document's own clause and section numbers and naming the file and revision as the source. Never put file content as base64 in a table. Warns if the checksum is already registered.",
    inputSchema: obj(
      {
        filename: str("File name"),
        bytes: { type: "integer", description: "Size in bytes" },
        mime_type: str("For example application/pdf"),
        sha256: str("Checksum of the content"),
        description: str("What the file contains and what it is good for"),
        source: str("Where it came from: system, sender, path"),
      },
      ["filename"],
    ),
    rpc: "skillhub_register_document",
    needsAgent: true,
  },
  {
    name: "skillhub_retire",
    description:
      "Retire something of YOUR OWN that no longer applies: a skill, a note or a document record. Requires a reason -- whoever finds it next needs to know why it stopped applying. Nothing is deleted: retired content leaves search but stays readable, because a real delete here cannot be undone by anyone. You cannot retire another agent's work; publish a better version under your own name instead.",
    inputSchema: obj({
      kind: str("What to retire: skill, note or document."),
      id: str("The slug for a skill, the id for a note or document."),
      reason: str("Why it no longer applies. Required."),
      superseded_by: str("For a skill: the slug that replaces it, if there is one."),
    }, ["kind", "id", "reason"]),
    rpc: "skillhub_retire",
    needsAgent: true,
  },
  {
    name: "skillhub_whoami",
    description:
      "Which agent the gateway sees you as, if you are unsure of your identifier. Also shows what the agent registry says about you and what you have contributed.",
    inputSchema: obj({}),
    rpc: "skillhub_whoami",
    needsAgent: true,
  },
  {
    name: "skillhub_report",
    description:
      "A plain-text summary to paste to a human. Who did what, new skills, new tables and what is waiting to be dealt with.",
    inputSchema: obj({ days: int("Days back", 1) }),
    rpc: "skillhub_report",
    raw: true,
  },
];

async function callRpc(fn: string, args: Record<string, unknown>): Promise<unknown> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
    },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  if (!res.ok) {
    let detail = text;
    try {
      const j = JSON.parse(text);
      detail = j.message ?? j.hint ?? text;
    } catch { /* keep the raw text */ }
    throw new Error(detail);
  }
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

const rpcOk = (id: unknown, result: unknown) => ({ jsonrpc: "2.0", id, result });
const rpcErr = (id: unknown, code: number, message: string) => ({ jsonrpc: "2.0", id, error: { code, message } });

/** Embeds a question and returns the nearest objects. null when no endpoint is configured. */
async function semanticSearch(query: string, maxHits: number): Promise<unknown[] | null> {
  const url = Deno.env.get("EMBEDDING_URL") ?? "";
  if (!url) return null;
  const model = Deno.env.get("EMBEDDING_MODEL") ?? "text-embedding-3-small";
  const key = Deno.env.get("EMBEDDING_KEY");
  const r = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(key ? { Authorization: `Bearer ${key}` } : {}) },
    body: JSON.stringify({ model, input: query }),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`The embeddings endpoint answered ${r.status}: ${t.slice(0, 200)}`);
  const vector = JSON.parse(t).data?.[0]?.embedding;
  return await callRpc("skillhub_similar", {
    query_vector: JSON.stringify(vector), model, max_hits: maxHits,
  }) as unknown[];
}

async function handle(body: any, agent: string): Promise<unknown | null> {
  const { id, method, params } = body ?? {};

  if (method === "initialize") {
    return rpcOk(id, {
      protocolVersion: PROTOCOL,
      capabilities: { tools: {} },
      serverInfo: { name: "skillhub", title: "Shared data store", version: "1.1.0" },
      // These three tool names were skillhub_oversikt / _regler / _sok until 2026-09-14 --
      // the pre-refactor Swedish names, none of which has existed since. Any client that
      // does show `instructions` was being sent to three tools that do not exist.
      instructions:
        "Tools for the organisation's shared data store. Run skillhub_overview first in a new session, and skillhub_rules before you write anything. Always run skillhub_search before creating something new -- publishing refuses without it. Ownership of what you write is filled in from your API key and cannot be set by you.",
    });
  }

  // Notifications carry no id and must not be answered.
  if (typeof method === "string" && method.startsWith("notifications/")) return null;

  if (method === "tools/list") {
    return rpcOk(id, {
      tools: TOOLS.map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema })),
    });
  }

  if (method === "tools/call") {
    const name_ = params?.name;
    const tool = TOOLS.find((t) => t.name === name_);
    if (!tool) return rpcErr(id, -32602, `Unknown tool: ${name_}`);

    const args: Record<string, unknown> = { ...(params?.arguments ?? {}) };
    if (tool.needsAgent) {
      if (!agent) {
        return rpcOk(id, {
          isError: true,
          content: [{
            type: "text",
            text: "The gateway sent no agent identity, so the write is refused. Check that the call goes through /skillhub with your apikey header.",
          }],
        });
      }
      args.agent = agent;
    }
    if (tool.passAgent && agent) args.agent = agent;

    try {
      if (tool.rpc === "__semantic__") {
        const hits = await semanticSearch(String(args.query ?? ""), Number(args.max_hits ?? 5));
        if (hits === null) {
          return rpcOk(id, {
            isError: true,
            content: [{
              type: "text",
              text: "Semantic search is off: no embedding endpoint is configured. Use skillhub_search, which matches words and always works.",
            }],
          });
        }
        return rpcOk(id, { content: [{ type: "text", text: JSON.stringify(hits, null, 2) }] });
      }
      const answer = await callRpc(tool.rpc, args);

      // A keyword search that finds nothing tries meaning before giving up.
      //
      // Measured 2026-09-12: the rule for reading a column lived in an English comment, the
      // user asked in Swedish, and search('defekter') returned zero rows while
      // search('sentinel') returned the rule. The agent did everything right -- overview,
      // rules, search -- and still answered a total thirty-eight times too high, because it
      // did not then reach for the semantic tool on its own.
      //
      // So the house retries instead of the agent having to. A Swedish question now reaches
      // an English schema comment at 0.50 similarity. Leaving this to the agent's judgement
      // is the version that fails silently.
      if (tool.rpc === "skillhub_search" && Array.isArray(answer) && answer.length === 0) {
        const hits = await semanticSearch(String(args.query ?? ""), Number(args.max_hits ?? 5));
        if (hits && Array.isArray(hits) && hits.length > 0) {
          return rpcOk(id, {
            content: [{
              type: "text",
              text: JSON.stringify({
                keyword_hits: 0,
                note: "No word matched, so these were found by MEANING instead -- which also works across languages, e.g. a Swedish question against an English comment. `kind: schema` is a table or column comment: that is where 'how this data has to be read' is written down. Read the object in full before you compute anything from it.",
                semantic_hits: hits,
              }, null, 2),
            }],
          });
        }
      }

      const text = tool.raw && typeof answer === "string" ? answer : JSON.stringify(answer, null, 2);
      return rpcOk(id, { content: [{ type: "text", text }] });
    } catch (e) {
      return rpcOk(id, {
        isError: true,
        content: [{ type: "text", text: `Error from the data store: ${e instanceof Error ? e.message : String(e)}` }],
      });
    }
  }

  if (method === "ping") return rpcOk(id, {});
  return rpcErr(id, -32601, `Unknown method: ${method}`);
}

Deno.serve(async (req: Request) => {
  if (req.method === "GET" || req.method === "HEAD") {
    // Streamable HTTP: clients try GET for SSE. This server is request/response only.
    return new Response("The skillhub MCP server answers POST.", { status: 405, headers: { Allow: "POST" } });
  }
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  // Kong key-auth sets this. Without the gateway it is absent, and writes are refused.
  const agent = req.headers.get("x-consumer-username") ?? "";

  let body: any;
  try {
    body = await req.json();
  } catch {
    return Response.json(rpcErr(null, -32700, "Invalid JSON"), { status: 400 });
  }

  const answer = await handle(body, agent);
  if (answer === null) return new Response(null, { status: 202 });
  return Response.json(answer, { headers: { "Content-Type": "application/json" } });
});
