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
// Two protocol eras, served on the same endpoint.
//
// 2026-07-28 removed the initialize handshake and made every request carry its own version
// and client capabilities in _meta -- the protocol became stateless at the transport level,
// which this server always was. So the bump is additive: server/discover (the one MUST),
// resultType and serverInfo on every result, cache hints on tools/list, and a version check
// that answers -32022 with the list we support. The initialize handshake stays for legacy
// clients; a request that carries modern _meta is served the modern way, and one that opens
// with initialize is served the legacy way, which is exactly what the spec's dual-era server
// is allowed to do. Nothing on an existing device has to change.
const PROTOCOL_MODERN = "2026-07-28";
const PROTOCOL_LEGACY = "2025-03-26";
const SUPPORTED_VERSIONS = [PROTOCOL_MODERN, PROTOCOL_LEGACY];
const SERVER_INFO = { name: "skillhub", title: "Shared data store", version: "1.1.0" };
const META_VERSION = "io.modelcontextprotocol/protocolVersion";
const META_CLIENT_CAPS = "io.modelcontextprotocol/clientCapabilities";
const META_SERVER_INFO = "io.modelcontextprotocol/serverInfo";
const INSTRUCTIONS =
  "Tools for the organisation's shared data store. Run skillhub_overview first in a new session, and skillhub_rules before you write anything. Always run skillhub_search before creating something new -- publishing refuses without it. Ownership of what you write is filled in from your API key and cannot be set by you.";
// Cache hints required on list results from 2026-07-28. The tool list only changes with a
// deploy, so an hour is conservative; private because the answer depends on the caller's key.
const LIST_CACHE = { ttlMs: 3_600_000, cacheScope: "private" };

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
      "Start here in a new session: the state of the shared store. Counts of tables and skills, active agents, every table with its comment and row count, where data came from and how fresh it is, and how much is waiting to be cleaned up. It also shows what became of the structure requests YOU filed -- open, or the caretaker's answer -- so you do not have to guess whether a delivery is still waiting.",
    inputSchema: obj({}),
    rpc: "skillhub_overview",
    needsAgent: true,
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
      "Search by MEANING when keyword search finds nothing but the subject should exist. Embeds your question and compares it with everything indexed. Returns which objects are relevant; read them with skillhub_read. A hit on a long object names the section it matched in (matched), so you know where to start reading; skillhub_read still gives the whole object.",
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
      "Ask for somewhere to put structured data. Two cases, and the second is the one people miss: no table fits at all, OR a table fits but is MISSING A FIELD you need -- ask for the column, do not drop the field and do not retire the source that still holds it. Use it the moment you notice you are about to lose something because there is nowhere to put it: say what the data is for and list the fields. If the rows are in a file, upload it first (skillhub_upload_url) and pass document_id and natural_key -- the caretaker loads it when building the table. Attach sample_rows only for a handful of rows that exist in no file. You cannot create tables yourself -- that keeps the data model deliberate -- but the caretaker sees every request and is the only one who can tell that two people asked for the same thing. It answers with existing tables and other open requests that look related: read them, because a column on something that exists beats a table beside it.",
    inputSchema: obj({
      purpose: str("What the data is for, in a sentence. The decision between a column and a new table is made on this, not on the field names."),
      fields: { type: "array", items: { type: "string" },
        description: "The fields you need, e.g. [\"supplier\",\"audit_date\",\"score\",\"deviations\",\"status\",\"auditor\"]." },
      sample_rows: { type: "array", items: { type: "object" },
        description: "A few rows that exist in NO file, as objects, at most 200. Rows from a file are never pasted here: skillhub_upload_url, then document_id." },
      suggested_name: str("A name you would give the table, if you have one in mind."),
      observations: { type: "array", items: { type: "string" },
        description: "What you NOTICED about the data, one sentence each, naming the column: sentinel values ('hours_spent 999 means not recorded'), spellings ('status has closed in three casings'), units, blanks. This is the most valuable thing you contribute -- the caretaker's loader writes it into the column comments, so the next agent is warned. Said only in chat it is lost." },
      document_id: str("The id from skillhub_upload_url, when the rows come from a file you uploaded. The caretaker then loads the file server-side; you never retype rows."),
      natural_key: str("The column a re-delivery upserts on, e.g. ticket_no. Required when a file is attached."),
      target_table: str("Only when you mean an EXISTING table and are asking for a column on it."),
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
    name: "skillhub_upload_url",
    description:
      "Hand a FILE of rows to the store without retyping them: registers the file and returns a one-time upload URL plus the exact curl line. Upload the bytes with that line (the file goes beside the model, not through it), then either skillhub_load_file into a table that already exists, or skillhub_request_structure with document_id, natural_key and your observations so the caretaker builds the table and loads the file. CSV today; save a spreadsheet as CSV first. Never paste rows into a chat or a tool argument -- sixty rows that way took 36 calls and stopped at 19.",
    inputSchema: obj({
      filename: str("The file's name, e.g. tickets_export_2026-09.csv"),
      sha256: str("sha256 of the file (sha256sum <file>). Names the upload path and lets the store spot the same file delivered twice."),
      description: str("What the file contains and where it came from: 'monthly export of support tickets from the case system'."),
      bytes: { type: "integer", description: "Size in bytes, if you know it." },
    }, ["filename", "sha256", "description"]),
    rpc: "__upload_url__",
    needsAgent: true,
  },
  {
    name: "skillhub_load_file",
    description:
      "Load an uploaded CSV into a table that ALREADY EXISTS, upserting on a natural key -- this is how next month's export goes in without the caretaker. Reads the file server-side, no row passes through you. Refuses if the table does not exist: then use skillhub_request_structure with the document_id instead, and the caretaker loads it when resolving. Registers the delivery (file, hash, inserted, updated).",
    inputSchema: obj({
      document_id: str("The id skillhub_upload_url returned, after the upload finished."),
      target_table: str("An existing table in public that follows the convention."),
      natural_key: str("The column to upsert on, e.g. ticket_no. Must be a column of the table and present in every row."),
      source_system: str("Where the export comes from, for the delivery register. Optional."),
    }, ["document_id", "target_table", "natural_key"]),
    rpc: "__load_file__",
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

// Every result carries resultType ("complete" for an ordinary answer) and the server's
// identity in _meta, both from 2026-07-28. Legacy clients ignore fields they do not know, and
// the spec requires modern clients to treat an ABSENT resultType as complete -- so adding it
// unconditionally is safe in both directions.
const rpcOk = (id: unknown, result: Record<string, unknown>) => ({
  jsonrpc: "2.0", id,
  result: {
    resultType: "complete",
    ...result,
    _meta: { ...((result._meta as Record<string, unknown> | undefined) ?? {}), [META_SERVER_INFO]: SERVER_INFO },
  },
});
const rpcErr = (id: unknown, code: number, message: string, data?: unknown) =>
  ({ jsonrpc: "2.0", id, error: { code, message, ...(data === undefined ? {} : { data }) } });
// Errors the spec says must travel with HTTP 400 on Streamable HTTP.
const BAD_REQUEST_CODES = new Set([-32602, -32021, -32022]);

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

// ---- Files as transport (DECISIONS.md 20) --------------------------------------------
// The bytes go to Storage with a signed URL the agent uses from its own shell; the loader
// reads them back here with the service key and upserts through skillhub_load_rows. No row
// is ever emitted by the model.
const BUCKET = "deliveries";
const PUBLIC_URL = (Deno.env.get("SUPABASE_PUBLIC_URL") ?? "").replace(/\/$/, "");
const storageHeaders = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` };

async function signedUploadUrl(path: string): Promise<string> {
  const r = await fetch(`${SUPABASE_URL}/storage/v1/object/upload/sign/${BUCKET}/${path}`, { method: "POST", headers: storageHeaders });
  const t = await r.text();
  if (!r.ok) throw new Error(`Storage would not sign an upload for ${path}: ${r.status} ${t.slice(0, 200)}`);
  const rel = JSON.parse(t).url as string;            // "/object/upload/sign/<bucket>/<path>?token=..."
  const base = PUBLIC_URL || SUPABASE_URL;
  return `${base}/storage/v1${rel.startsWith("/") ? rel : "/" + rel}`;
}
async function objectExists(path: string): Promise<boolean> {
  const r = await fetch(`${SUPABASE_URL}/storage/v1/object/info/authenticated/${BUCKET}/${path}`, { headers: storageHeaders });
  return r.ok;
}
async function downloadObject(path: string): Promise<string> {
  const r = await fetch(`${SUPABASE_URL}/storage/v1/object/authenticated/${BUCKET}/${path}`, { headers: storageHeaders });
  if (r.status === 404 || r.status === 400) throw new Error(`The file is registered but not uploaded yet (${path}). Run the curl line skillhub_upload_url gave you, then try again.`);
  if (!r.ok) throw new Error(`Storage answered ${r.status} for ${path}`);
  return await r.text();
}
/** RFC 4180-ish: quoted fields, doubled quotes, commas or semicolons, CRLF. Header row required. */
function parseCsv(text: string): Record<string, string>[] {
  const rows: string[][] = []; let row: string[] = []; let cell = ""; let q = false;
  const src = text.replace(/^\uFEFF/, "");
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (q) { if (c === '"') { if (src[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += c; continue; }
    if (c === '"') q = true;
    else if (c === "," || c === ";") { row.push(cell); cell = ""; }
    else if (c === "\n" || c === "\r") { if (c === "\r" && src[i + 1] === "\n") i++; row.push(cell); cell = ""; if (row.some((x) => x !== "")) rows.push(row); row = []; }
    else cell += c;
  }
  if (cell !== "" || row.length) { row.push(cell); if (row.some((x) => x !== "")) rows.push(row); }
  if (rows.length < 2) throw new Error("The file has no data rows under its header.");
  const header = rows[0].map((h) => h.trim().toLowerCase().replace(/[^a-z0-9_]+/g, "_").replace(/^_+|_+$/g, ""));
  return rows.slice(1).map((r) => Object.fromEntries(header.map((h, i) => [h, (r[i] ?? "").trim()])));
}
async function documentPath(id: string): Promise<{ path: string; filename: string; sha256: string }> {
  const d = await callRpc("skillhub_read", { kind: "document", id }) as any;
  const path = d?.path ?? d?.document?.path; const filename = d?.filename ?? d?.document?.filename; const sha256 = d?.sha256 ?? d?.document?.sha256;
  if (!path) throw new Error(`Document ${id} has no upload path. Register it with skillhub_upload_url (not register_document) so the bytes have somewhere to go.`);
  return { path, filename, sha256 };
}

async function handle(body: any, agent: string): Promise<unknown | null> {
  const { id, method, params } = body ?? {};
  const meta = (params?._meta ?? {}) as Record<string, unknown>;

  // Modern requests declare their version per request. Unknown -> -32022 with what we do
  // support, so the client can retry with one of them. A request with no declaration is a
  // legacy client and is served as before.
  const requested = typeof meta[META_VERSION] === "string" ? String(meta[META_VERSION]) : undefined;
  if (requested !== undefined) {
    if (!SUPPORTED_VERSIONS.includes(requested)) {
      return rpcErr(id, -32022, "Unsupported protocol version",
        { supported: SUPPORTED_VERSIONS, requested });
    }
    // A modern request is malformed without client capabilities. Only checked when the
    // client has declared a modern version -- legacy clients never send either field.
    if (requested === PROTOCOL_MODERN && typeof meta[META_CLIENT_CAPS] !== "object") {
      return rpcErr(id, -32602, `Missing required _meta field ${META_CLIENT_CAPS}`);
    }
  }

  // The one method 2026-07-28 says a server MUST implement. Also the backward-compatibility
  // probe: a dual-era client sends it first and falls back to initialize on anything that is
  // not a recognised modern answer.
  if (method === "server/discover") {
    return rpcOk(id, {
      supportedVersions: SUPPORTED_VERSIONS,
      capabilities: { tools: {} },
      instructions: INSTRUCTIONS,
      ...LIST_CACHE,
    });
  }

  // Legacy handshake, kept for clients on 2025-11-25 and earlier. A modern client never sends
  // it; a legacy client cannot proceed without it.
  if (method === "initialize") {
    return rpcOk(id, {
      protocolVersion: PROTOCOL_LEGACY,
      capabilities: { tools: {} },
      serverInfo: SERVER_INFO,
      instructions: INSTRUCTIONS,
    });
  }

  // Notifications carry no id and must not be answered.
  if (typeof method === "string" && method.startsWith("notifications/")) return null;

  if (method === "tools/list") {
    // Deterministic order (a static array) so clients can cache and prompt caches hit.
    return rpcOk(id, {
      tools: TOOLS.map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema })),
      ...LIST_CACHE,
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
      if (tool.rpc === "__upload_url__") {
        const sha = String(args.sha256 ?? "").toLowerCase();
        if (!/^[a-f0-9]{64}$/.test(sha)) throw new Error("sha256 must be the 64-hex digest of the file: sha256sum <file>.");
        const filename = String(args.filename ?? "").replace(/[^A-Za-z0-9._ -]/g, "_");
        const path = `${sha}/${filename}`;
        const reg = await callRpc("skillhub_register_document", {
          agent, filename, sha256: sha, description: String(args.description ?? ""), bytes: args.bytes ?? null,
          mime_type: filename.toLowerCase().endsWith(".csv") ? "text/csv" : null, source: "uploaded by " + agent, path,
        }) as any;
        // Same bytes, same path: a file already uploaded needs no second upload, and a signed
        // URL would answer 409 to one. Say so instead of handing out a curl line that fails.
        if (await objectExists(path)) {
          return rpcOk(id, { content: [{ type: "text", text: JSON.stringify({
            document_id: reg.id, path, already_uploaded: true, duplicate_of: reg.duplicate_of ?? null,
            then: "This exact file is already in the store (same sha256). Skip the upload: go straight to skillhub_load_file into an existing table, or skillhub_request_structure with this document_id.",
          }, null, 2) }] });
        }
        const url = await signedUploadUrl(path);
        return rpcOk(id, { content: [{ type: "text", text: JSON.stringify({
          document_id: reg.id, path, already_uploaded: false, duplicate_of: reg.duplicate_of ?? null,
          upload_with: `curl -sS -X PUT -H 'content-type: text/csv' --upload-file '<the file>' '${url}'`,
          then: "Run that from your shell; no API key is needed, the URL carries its own. When it returns, either skillhub_load_file(document_id, target_table, natural_key) into a table that exists, or skillhub_request_structure with document_id, natural_key and your observations so the caretaker builds the table and loads it.",
          note: "The URL is single-use and expires. The file goes straight to the store; nothing in it passes through you.",
        }, null, 2) }] });
      }
      if (tool.rpc === "__load_file__") {
        const { path, filename, sha256 } = await documentPath(String(args.document_id ?? ""));
        const rows = parseCsv(await downloadObject(path));
        let inserted = 0, updated = 0, slices = 0;
        for (let i = 0; i < rows.length; i += 500) {
          const r = await callRpc("skillhub_load_rows", {
            agent, target_table: args.target_table, natural_key: args.natural_key, rows: rows.slice(i, i + 500),
            file_sha256: sha256, filename, source_system: args.source_system ?? null, register: i + 500 >= rows.length,
          }) as any;
          inserted += Number(r.inserted ?? 0); updated += Number(r.updated ?? 0); slices++;
        }
        return rpcOk(id, { content: [{ type: "text", text: JSON.stringify({
          table: args.target_table, natural_key: args.natural_key, file: filename, rows_in_file: rows.length,
          inserted, updated, slices, delivery_registered: true,
          note: "Read skillhub_read kind=table for the column comments before you analyse: that is where the reading rules live.",
        }, null, 2) }] });
      }
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

  // Removed in 2026-07-28; harmless to keep answering for legacy clients.
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
  // The spec requires HTTP 400 for malformed modern requests and unsupported versions, so a
  // dual-era client can tell a modern server from a legacy one by the body of the 400.
  const code = (answer as { error?: { code?: number } }).error?.code;
  const status = code !== undefined && BAD_REQUEST_CODES.has(code) ? 400 : 200;
  return Response.json(answer, { status, headers: { "Content-Type": "application/json" } });
});
