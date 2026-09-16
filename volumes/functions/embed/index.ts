// Embedding: keeps the vector index in step with the content.
//
// The principle is AnythingLLM's: whoever owns the intake owns the index. There is no
// app here, so the database and this function do the work. An agent writes a note and it
// becomes findable by meaning shortly after, without the agent knowing vectors exist.
// The alternative -- the endpoint in every agent's prompt -- produces an index that
// reflects who was diligent rather than what exists, and spreads the key to every laptop.
//
// Called by pg_cron over pg_net, or by hand through the gateway on /embed (service role
// only, never an agent key). With no EMBEDDING_URL it does nothing and says so.
//
// Since 2026-09-16 it configures itself. Three variables -- EMBEDDING_URL, EMBEDDING_KEY,
// EMBEDDING_MODEL -- and the function finds out the rest by asking the endpoint: which
// dimension the model returns (and sets the vector column to it while the table is empty),
// and how much text one input may carry (TEI's /info, vLLM's /v1/models, or a probe). What it
// found is written to platform.embedder and shown by skillhub_overview, together with how the
// last run went, so a silent cron cannot fail silently.
//
// Objects are embedded in CHUNKS cut by the database on the object's own headings, sized to
// what the endpoint accepts. So an embedder built for RAG (512-2048 tokens) indexes a
// 14,000-character skill in full instead of refusing it, and section seven of a long skill
// is findable, not only its opening.
//
// Idempotent: embed_candidates only hands out what lacks a current embedding, and
// text_hash means changed text is embedded again while unchanged text is skipped.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "http://api-gw:8000";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
// The full endpoint, however it was written down. An OpenAI-compatible base URL comes in
// three shapes and all three were pasted into a panel here (2026-09-16): the host on its
// own, the host with /v1, and the complete path. The first two answer 404, which reaches
// the store as "the endpoint answered 404" and nothing about why. So normalise instead.
function embeddingsEndpoint(raw: string): string {
  const u = raw.trim().replace(/\/+$/, "");
  if (!u) return "";
  if (/\/embeddings$/.test(u)) return u;          // already the endpoint
  if (/\/v\d+$/.test(u)) return `${u}/embeddings`; // the usual "base URL"
  try {                                           // the host on its own
    if (new URL(u).pathname === "/") return `${u}/v1/embeddings`;
  } catch { /* not a URL we can parse; leave it to the fetch to complain */ }
  return u;                                       // some other path: assume it was meant
}
const EMBEDDING_URL = embeddingsEndpoint(Deno.env.get("EMBEDDING_URL") ?? "");
const EMBEDDING_KEY = Deno.env.get("EMBEDDING_KEY") ?? "";
const EMBEDDING_MODEL = Deno.env.get("EMBEDDING_MODEL") ?? "text-embedding-3-small";

// Inputs per request to the embedder. Providers cap this and refuse the whole request
// above it -- text-embeddings-inference at --max-client-batch-size (32 by default, 8 on a
// CPU deployment measured 2026-09-14), OpenAI at 2048. Chunks are sent in slices of this
// size, so a small server never sees a request it will refuse.
const EMBEDDING_MAX_INPUTS = Math.max(1, Number(Deno.env.get("EMBEDDING_MAX_INPUTS") ?? "8"));
// Set it and the probe is skipped: this many characters per chunk, whatever the endpoint
// says. 0 (the default) means find out.
const EMBEDDING_MAX_CHARS = Math.max(0, Number(Deno.env.get("EMBEDDING_MAX_CHARS") ?? "0"));
// vLLM's own truncate_prompt_tokens, sent only when set. OpenAI rejects unknown fields.
const EMBEDDING_TRUNCATE_TOKENS = Number(Deno.env.get("EMBEDDING_TRUNCATE_TOKENS") ?? "0") || 0;
// Characters per token, conservatively, for mixed Swedish and English -- measured around
// 3.3 on this store's skills with cl100k; multilingual tokenizers run lower. With the 10 %
// headroom a chunk sized from a token limit stays under it.
const CHARS_PER_TOKEN = 3.0;
const PROBE_TTL_MS = 24 * 3600 * 1000;

type Candidate = { source: string; id: string; chunk: number; head: string; text: string; text_hash: string };
type Settings = {
  url?: string | null; model?: string | null; dimension?: number | null; max_tokens?: number | null;
  max_chars?: number | null; limit_source?: string | null; probed_at?: string | null; status?: string | null;
  chars_per_token?: number | null; table_dimension?: number | null;
};

async function rpc(fn: string, args: Record<string, unknown>): Promise<any> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${fn}: ${text}`);
  try { return JSON.parse(text); } catch { return text; }
}

// Tokens the endpoint reported for the last request (usage.prompt_tokens), 0 if it did not
// say. The probe uses it to measure characters per token for this tokenizer.
let lastPromptTokens = 0;
// Truncation is a RETRY, never the default. Armed on the first request, vLLM cuts an
// over-budget input instead of refusing it -- and a rule indexed in part is worse than one
// not indexed, because nothing says so. It was not observable either: usage.prompt_tokens
// is the sum over the whole request, so a batch of eight hides which input was cut, and an
// estimate from the assumed ratio can never fire because the chunk size is derived from
// that same ratio. Measured 2026-09-16 against a client vLLM: eight chunks of 6,773
// characters of part numbers and hex came back at exactly 8 x 2,048 tokens -- every one
// cut -- and the counter said zero.
//
// So: send without it. An over-budget input makes the request fail, the failure isolates
// down to the single input that caused it, and only then is truncation asked for. Then the
// cut is exactly one input, we know which, and the count is a fact rather than a guess.
// EMBEDDING_TRUNCATE_TOKENS still forces it on every request, for an endpoint that needs it.
let truncateTokens = EMBEDDING_TRUNCATE_TOKENS;

async function embedOnce(texts: string[], truncate = truncateTokens): Promise<number[][]> {
  if (!EMBEDDING_URL) throw new Error("EMBEDDING_URL is not set.");
  const res = await fetch(EMBEDDING_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(EMBEDDING_KEY ? { Authorization: `Bearer ${EMBEDDING_KEY}` } : {}) },
    body: JSON.stringify({ model: EMBEDDING_MODEL, input: texts,
      ...(truncate ? { truncate_prompt_tokens: truncate } : {}) }),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`The embeddings endpoint answered ${res.status}: ${text.slice(0, 300)}`);
  const data = JSON.parse(text);
  lastPromptTokens = Number(data.usage?.prompt_tokens ?? 0) || 0;
  const vectors: number[][] = (data.data ?? []).map((d: any) => d.embedding);
  if (vectors.length !== texts.length) throw new Error(`Got ${vectors.length} vectors for ${texts.length} texts.`);
  return vectors;
}

// A sample in the store's own mix of Swedish and English, 1,000 characters, for measuring
// how this tokenizer counts. Qwen's tokenizer spends more tokens on Swedish than cl100k
// does; a chunk sized on an assumed ratio would be refused by a 2,048-token vLLM.
const RATIO_SAMPLE = (
  "Avvikelsen registrerades i kvalitetsregistret med leverantörens artikelnummer och en kort beskrivning av felet. " +
  "The supplier surveillance rule says every approved supplier is audited within twelve months of the last audit. " +
  "Kolumnen hours_spent innehåller värdet 999 för ärenden där tiden inte registrerats; exkludera dem ur summor och medelvärden. " +
  "Register the document, keep its own clause numbering, and never present condensed text inside quotation marks. " +
  "Nästa månads export laddas med skillhub_load_file mot samma tabell och upsertas på ticket_no utan att någon skriver om raderna. "
).repeat(3).slice(0, 1000);

/** A sample of what this store actually holds, because that is what has to fit. Prose is
 *  the wrong yardstick: the same endpoint that spends one token per 3.9 characters of
 *  Swedish spends one per 3.3 on a table of part numbers and hex, and a chunk sized on the
 *  first is cut when it holds the second. Falls back to the prose sample on an empty store. */
async function ratioSamples(): Promise<string[]> {
  try {
    const c = await rpc("embed_candidates", { max_rows: 8, max_chars: 100000 }) as Candidate[];
    const longest = (c ?? []).map((x) => x.text).filter((t) => t.length >= 500)
      .sort((a, b) => b.length - a.length).slice(0, 3).map((t) => t.slice(0, 2000));
    if (longest.length) return longest;
  } catch { /* an empty or unreachable store: the prose sample still says something */ }
  return [RATIO_SAMPLE];
}

/** Characters per token for this endpoint's tokenizer, measured; the constant if the endpoint
 *  reports no usage. */
async function measureCharsPerToken(): Promise<{ ratio: number; measured: boolean }> {
  // The WORST of a few, not an average: chunks are sized once for everything the store
  // holds, so the sample that fits fewest characters per token is the one that decides.
  let worst = 0;
  for (const sample of await ratioSamples()) {
    try {
      await embedOnce([sample], 0);
      if (lastPromptTokens > 0) {
        const r = sample.length / lastPromptTokens;
        worst = worst === 0 ? r : Math.min(worst, r);
      }
    } catch { /* try the next one */ }
  }
  return worst > 0 ? { ratio: worst, measured: true } : { ratio: CHARS_PER_TOKEN, measured: false };
}

/** Embeds texts in slices the endpoint accepts. A failed slice is retried one text at a
 *  time, so one bad input does not sink its slice-mates; the texts that still fail come
 *  back as null with their error.
 *
 *  Truncation is counted, because with truncate_prompt_tokens armed the endpoint no longer
 *  refuses an over-budget input -- it cuts it, and a rule indexed in part is worse than one
 *  not indexed at all, since nothing says so. Two signals: a single-input request whose
 *  usage equals the limit exactly is truncation with near-certainty, and any text longer
 *  than the measured ratio allows is counted as suspected. Both make the same number go up. */
let lastRequests = 0;
let lastTruncated = 0;
let longestCut = 0;       // characters of the longest input that had to be cut
let tokenBudget = 0;      // max_tokens, once the probe knows it
let charsPerToken = CHARS_PER_TOKEN;
async function embed(texts: string[]): Promise<{ vectors: (number[] | null)[]; errors: Map<number, string>; cut: Set<number> }> {
  const vectors: (number[] | null)[] = new Array(texts.length).fill(null);
  const errors = new Map<number, string>();
  const cut = new Set<number>();
  lastRequests = 0; lastTruncated = 0; longestCut = 0;
  for (let i = 0; i < texts.length; i += EMBEDDING_MAX_INPUTS) {
    const slice = texts.slice(i, i + EMBEDDING_MAX_INPUTS);
    try {
      const vs = await embedOnce(slice); lastRequests++;
      vs.forEach((v, j) => vectors[i + j] = v);
    } catch (_e) {
      // Something in this slice was refused. Find out which, keep the rest.
      for (let j = 0; j < slice.length; j++) {
        try { vectors[i + j] = (await embedOnce([slice[j]]))[0]; lastRequests++; continue; }
        catch (e2) {
          // Alone and still refused. If it is a length problem, truncation gets it in --
          // and now we know exactly which input was cut and how long it was.
          const budget = truncateTokens || tokenBudget;
          if (budget) {
            try {
              await embedOnce([slice[j]], budget); lastRequests++;
              // The vector is deliberately NOT kept. A chunk that had to be cut is a chunk
              // the store sized wrong, and half a rule indexed as if it were whole is the
              // failure this is here to prevent. The object stays a candidate, the ratio
              // comes down, and the next run embeds it in pieces that fit.
              cut.add(i + j); lastTruncated++; longestCut = Math.max(longestCut, slice[j].length);
              continue;
            } catch { /* not a length problem, or truncation is not supported */ }
          }
          errors.set(i + j, e2 instanceof Error ? e2.message : String(e2));
        }
      }
    }
  }
  return { vectors, errors, cut };
}

// ---- Finding out what the endpoint is ---------------------------------------------------

function origin(url: string): string {
  const u = new URL(url);
  return `${u.protocol}//${u.host}`;
}

/** How many tokens one input may carry, if the server will say. TEI answers /info with
 *  max_input_length; vLLM answers /v1/models with max_model_len. OpenAI answers neither. */
async function askServerForLimit(): Promise<{ tokens: number; from: string } | null> {
  const auth = EMBEDDING_KEY ? { Authorization: `Bearer ${EMBEDDING_KEY}` } : {};
  const base = origin(EMBEDDING_URL);
  try {
    const r = await fetch(`${base}/info`, { headers: auth });
    if (r.ok) {
      const j = await r.json();
      const n = Number(j.max_input_length);
      if (n > 0) return { tokens: n, from: "tei /info" };
    }
  } catch { /* not TEI */ }
  try {
    const r = await fetch(`${base}/v1/models`, { headers: auth });
    if (r.ok) {
      const j = await r.json();
      const m = (j.data ?? []).find((d: any) => d.id === EMBEDDING_MODEL) ?? (j.data ?? [])[0];
      const n = Number(m?.max_model_len);
      if (n > 0) return { tokens: n, from: "vllm /v1/models" };
    }
  } catch { /* not vLLM */ }
  return null;
}

/** When nobody will say: send text of decreasing size until one is accepted. A refusal is
 *  any 4xx here, because the dimension probe already proved the key and the model work. */
async function probeLimitByTrying(): Promise<number> {
  const sizes = [24000, 12000, 6000, 3000, 1500];
  const word = "lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor ";
  for (const size of sizes) {
    const text = word.repeat(Math.ceil(size / word.length)).slice(0, size);
    try { await embedOnce([text]); return size; } catch { /* too long, try smaller */ }
  }
  return 1000;
}

/** Reuses what a previous run found, or probes: dimension from a real embedding, limit from
 *  the server or by trying. Writes the result to platform.embedder. */
async function settings(force: boolean): Promise<Settings> {
  const prev: Settings = (await rpc("embedder_get", {})) ?? {};
  const fresh = prev.probed_at && (Date.now() - Date.parse(prev.probed_at)) < PROBE_TTL_MS;
  const same = prev.url === EMBEDDING_URL && prev.model === EMBEDDING_MODEL;
  // A limit that came from EMBEDDING_MAX_CHARS is only valid while the variable still says
  // so; once it is unset, probe again. Found 2026-09-16: a 3,000-character override left by
  // a test survived the deploy that removed it.
  const envLimitStillApplies = EMBEDDING_MAX_CHARS
    ? (prev.limit_source === "env" && prev.max_chars === EMBEDDING_MAX_CHARS)
    : prev.limit_source !== "env";
  if (!force && fresh && same && prev.dimension && prev.max_chars && envLimitStillApplies) return prev;

  const dimension = (await embedOnce(["probe"]))[0].length;
  let max_tokens: number | null = null, max_chars: number, limit_source: string;
  // Held steady per model. The measurement samples whatever is waiting to be indexed, so a
  // day with a table of part numbers in the queue measures 1.3 characters per token and a
  // day with prose measures 3.9 -- and a chunk size that follows it moves back and forth,
  // which health would rightly report as the index being cut at the wrong size. The store
  // that once held content needing the smaller figure still holds it. A new model starts over.
  const prevRatio = same ? Number(prev.chars_per_token) || 0 : 0;
  let ratio = prevRatio || CHARS_PER_TOKEN;
  if (EMBEDDING_MAX_CHARS > 0) {
    max_chars = EMBEDDING_MAX_CHARS; limit_source = "env";
    const said = await askServerForLimit();       // still worth knowing, for the truncation count
    if (said) max_tokens = said.tokens;
  } else {
    const said = await askServerForLimit();
    if (said) {
      const m = await measureCharsPerToken();
      ratio = prevRatio && m.measured ? Math.min(prevRatio, m.ratio) : m.ratio;
      max_tokens = said.tokens; limit_source = said.from + (m.measured ? `, ${ratio.toFixed(2)} chars/token measured` : "");
      max_chars = Math.floor(said.tokens * ratio * 0.85);
    } else {
      const ok = await probeLimitByTrying();
      max_chars = Math.floor(ok * 0.9); limit_source = "probe";
    }
  }
  max_chars = Math.max(500, Math.min(max_chars, 60000));
  const s: Settings = { url: EMBEDDING_URL, model: EMBEDDING_MODEL, dimension, max_tokens, max_chars, limit_source,
    chars_per_token: ratio, probed_at: new Date().toISOString() };
  await rpc("embedder_save", { p: s });
  return { ...prev, ...s };
}

/** vLLM refuses an input over max_model_len unless asked to truncate; once the server is
 *  known to be vLLM, ask -- the chunk size keeps this from ever triggering, and if the
 *  ratio was still wrong the chunk is cut at the limit instead of lost. */
function armTruncation(s: Settings) {
  tokenBudget = EMBEDDING_TRUNCATE_TOKENS || s.max_tokens || 0;
  charsPerToken = Number(s.chars_per_token) || CHARS_PER_TOKEN;
}

/** The vector column has to be the model's dimension. Changed only while the table is
 *  empty; otherwise the store refuses with a message that says what to do. */
async function ensureDimension(dimension: number): Promise<string | null> {
  const cur = Number(((await rpc("embedder_status", {})) ?? {}).table_dimension);
  if (cur === dimension) return null;
  return String(await rpc("embed_set_dim", { wanted: dimension }));
}

/** One pass: take up to `batch` objects that lack a current embedding, embed their chunks,
 *  save each object whole. Returns what it managed. */
async function onePass(s: Settings, batch: number) {
  const candidates: Candidate[] = await rpc("embed_candidates", { max_rows: batch, max_chars: s.max_chars });
  if (!candidates.length) return { objects: 0, saved: 0, chunks: 0, truncated: 0, cutLongest: 0, requests: 0, errors: [] as string[] };

  // Group chunks by object, in the order the store gave them.
  const objects = new Map<string, Candidate[]>();
  for (const c of candidates) {
    const k = `${c.source}/${c.id}`;
    if (!objects.has(k)) objects.set(k, []);
    objects.get(k)!.push(c);
  }
  const { vectors, errors: embedErrors, cut } = await embed(candidates.map((c) => c.text));

  let saved = 0, savedChunks = 0;
  const errors: string[] = [];
  for (const [k, chunks] of objects) {
    const idx = chunks.map((c) => candidates.indexOf(c));
    const bad = idx.filter((i) => !vectors[i]);
    if (bad.length) {
      const why = cut.has(bad[0])
        ? `too long for the model at this chunk size (${candidates[bad[0]].text.length} characters); left unindexed on purpose rather than indexed in part`
        : embedErrors.get(bad[0]) ?? "no vector";
      errors.push(`${k}: chunk ${candidates[bad[0]].chunk + 1} of ${chunks.length}: ${why}`);
      continue;
    }
    try {
      await rpc("embed_save_chunks", {
        p_source: chunks[0].source, p_id: chunks[0].id, p_model: s.model,
        p_vectors: idx.map((i) => vectors[i]), p_heads: chunks.map((c) => c.head), p_text_hash: chunks[0].text_hash,
        p_chunk_chars: s.max_chars,
      });
      saved++; savedChunks += chunks.length;
    } catch (e) {
      errors.push(`${k}: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
  return { objects: objects.size, saved, chunks: savedChunks, truncated: lastTruncated,
           cutLongest: longestCut, requests: lastRequests, errors };
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  const batch = Math.min(Number(url.searchParams.get("batch") ?? "20"), 100);
  const force = url.searchParams.get("probe") === "1";
  // Seconds this call may spend. It keeps taking batches until nothing is waiting or the
  // budget is gone, because the alternative is one batch per cron tick: a store of five
  // thousand objects rebuilt at a hundred objects every five minutes is four hours with
  // half an index, and a rebuild is exactly what a model change asks for. Bounded, so the
  // edge runtime and pg_net both get their answer.
  const budgetMs = Math.min(Math.max(Number(url.searchParams.get("budget") ?? "60"), 1), 240) * 1000;
  const deadline = Date.now() + budgetMs;
  const started = Date.now();
  const now = () => new Date().toISOString();
  // One row per run, kept for seven days. platform.embedder holds the LAST run, which
  // cannot answer "has this been failing all night and recovering by morning".
  const note = (p: Record<string, unknown>) =>
    rpc("index_run_save", { p: { ...p, seconds: Number(((Date.now() - started) / 1000).toFixed(2)) } }).catch(() => {});

  if (!EMBEDDING_URL) {
    try { await rpc("embedder_save", { p: { status: "off", last_error: null, last_run: now() } }); } catch { /* the message below still stands */ }
    return Response.json({
      status: "off",
      explanation: "EMBEDDING_URL is not set, so nothing is embedded. Set EMBEDDING_URL, EMBEDDING_KEY and " +
        "EMBEDDING_MODEL in the service's Environment; the indexer works out dimension and input size itself. " +
        "Keyword search is unaffected.",
    });
  }

  let s: Settings;
  let dimNote: string | null = null;
  try {
    s = await settings(force);
    armTruncation(s);
    dimNote = await ensureDimension(s.dimension!);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    try { await rpc("embedder_save", { p: { url: EMBEDDING_URL, model: EMBEDDING_MODEL, status: "error", last_run: now(), last_error: message } }); } catch { /* reported below anyway */ }
    await note({ model: EMBEDDING_MODEL, error: message });
    return Response.json({ status: "error", message }, { status: 500 });
  }

  // Vectors whose object was retired, made private or deleted. The query side filters them
  // anyway, but an index that holds them reports numbers nobody can act on.
  let pruned = 0;
  try { pruned = Number(await rpc("embed_prune", {})) || 0; } catch { /* not fatal */ }

  try {
    let objects = 0, saved = 0, chunks = 0, truncated = 0, requests = 0, passes = 0, cutLongest = 0;
    const errors: string[] = [];
    let ranOut = false;
    for (;;) {
      const p = await onePass(s, batch);
      passes++;
      objects += p.objects; saved += p.saved; chunks += p.chunks;
      truncated += p.truncated; requests += p.requests; errors.push(...p.errors);
      cutLongest = Math.max(cutLongest, p.cutLongest);
      if (p.truncated > 0) break;   // the ratio is wrong for this content; resize, then go on
      if (p.objects === 0) break;                 // nothing left
      if (p.saved === 0) break;                   // no progress: everything in that pass failed
      if (Date.now() >= deadline) { ranOut = true; break; }
    }

    // A cut is a measurement: that input held more than the budget in the characters it
    // had, so the true ratio is below length/budget. Record a ratio under that and the
    // next run's chunks are smaller -- the store corrects itself instead of waiting for
    // somebody to notice a number nobody is watching.
    let ratioNote: string | null = null;
    if (truncated > 0 && s.limit_source === "env") {
      ratioNote = `${truncated} chunk(s) did not fit and were left unindexed. EMBEDDING_MAX_CHARS is pinning the chunk size at ${s.max_chars}; lower it (this content needs about ${Math.floor((cutLongest / tokenBudget) * 0.9 * tokenBudget * 0.85)}) or unset it and let the probe size them.`;
      await rpc("embedder_save", { p: { last_error: ratioNote } });
    } else if (truncated > 0 && cutLongest > 0 && tokenBudget > 0) {
      const safer = Math.max(1, Math.min(Number(s.chars_per_token) || CHARS_PER_TOKEN, (cutLongest / tokenBudget) * 0.9));
      if (safer < (Number(s.chars_per_token) || CHARS_PER_TOKEN)) {
        await rpc("embedder_save", { p: { chars_per_token: safer, max_chars: Math.floor(tokenBudget * safer * 0.85) } });
        ratioNote = `Chunks were too big for this content: ${truncated} did not fit and were left unindexed. Characters per token lowered to ${safer.toFixed(2)} and chunk size to ${Math.floor(tokenBudget * safer * 0.85)}; the next run embeds them in pieces that fit.`;
      }
    }
    await rpc("embedder_save", { p: { status: saved || !errors.length ? "ok" : "error", last_run: now(),
      last_embedded: saved, last_failed: errors.length, last_truncated: truncated,
      last_error: ratioNote ?? errors[0] ?? null } });

    await note({ model: s.model, dimension: s.dimension, objects, embedded: saved, chunks,
                 truncated, failed: errors.length, requests, pruned, error: ratioNote ?? errors[0] ?? null });

    return Response.json({
      status: "done",
      model: s.model, dimension: s.dimension, max_chars_per_chunk: s.max_chars, limit_from: s.limit_source,
      requests, max_inputs_per_request: EMBEDDING_MAX_INPUTS, passes,
      objects, embedded: saved, chunks, pruned,
      truncated, failed: errors.length, errors: errors.slice(0, 5),
      ...(ratioNote ? { resized: ratioNote } : {}),
      ...(dimNote ? { dimension_note: dimNote } : {}),
      comment: objects === 0 ? "Nothing was waiting."
        : ranOut ? `Budget of ${budgetMs / 1000}s spent -- run again to continue.`
        : errors.length && !saved ? "Nothing could be embedded; see errors."
        : "Everything that was waiting is embedded.",
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    try { await rpc("embedder_save", { p: { status: "error", last_run: now(), last_error: message } }); } catch { /* nothing more to do */ }
    await note({ model: EMBEDDING_MODEL, error: message });
    return Response.json({ status: "error", message }, { status: 500 });
  }
});
