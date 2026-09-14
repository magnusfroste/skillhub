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
// Idempotent: embed_candidates only hands out what lacks a current embedding, and
// text_hash means changed text is embedded again while unchanged text is skipped.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "http://api-gw:8000";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const EMBEDDING_URL = Deno.env.get("EMBEDDING_URL") ?? "";
const EMBEDDING_KEY = Deno.env.get("EMBEDDING_KEY") ?? "";
const EMBEDDING_MODEL = Deno.env.get("EMBEDDING_MODEL") ?? "text-embedding-3-small";
const EMBEDDING_DIM = Number(Deno.env.get("EMBEDDING_DIM") ?? "1536");

type Candidate = { source: string; id: string; text: string; text_hash: string };

async function rpc(fn: string, args: Record<string, unknown>): Promise<any> {
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
  if (!res.ok) throw new Error(`${fn}: ${text}`);
  try { return JSON.parse(text); } catch { return text; }
}

// Inputs per request to the embedder. Providers cap this and refuse the whole request
// above it -- text-embeddings-inference at --max-client-batch-size (32 by default, 8 on a
// CPU deployment measured 2026-09-14), OpenAI at 2048. The candidates a run fetches (the
// cron asks for 100) are sent in slices of this size, so a small server never sees a
// request it will refuse and nothing is silently left unembedded.
const EMBEDDING_MAX_INPUTS = Math.max(1, Number(Deno.env.get("EMBEDDING_MAX_INPUTS") ?? "8"));
/** Upstream requests made by the last embed() call -- reported in the response so the
 *  slicing is observable rather than assumed. */
export let lastRequests = 0;
export let lastTruncated = 0;

// Two ways to survive a model with a short context, and a client's vLLM at
// --max-model-len 2048 (2026-09-14) is the case in hand. An input over the limit is not
// truncated by vLLM by default -- the request is REFUSED with 400, and with it the other
// seven inputs in the same slice. A 14,000-character skill would then never be indexed
// and take its slice-mates down every five minutes, forever.
//   EMBEDDING_MAX_CHARS       client-side cap, provider-agnostic. 0 = off. About 3.5
//                             characters per token for mixed Swedish/English, so 6000 is
//                             safe for a 2048-token model. The first part of the text is
//                             what gets embedded; findability of the rest is the
//                             document-chunking work named in DECISIONS.md, not this knob.
//   EMBEDDING_TRUNCATE_TOKENS vLLM's own truncate_prompt_tokens, sent only when set.
//                             OpenAI rejects unknown fields, so never on by default.
const EMBEDDING_MAX_CHARS = Math.max(0, Number(Deno.env.get("EMBEDDING_MAX_CHARS") ?? "0"));
const EMBEDDING_TRUNCATE_TOKENS = Number(Deno.env.get("EMBEDDING_TRUNCATE_TOKENS") ?? "0") || 0;

/** Embeds a list of texts in slices the endpoint accepts. One bad input no longer sinks its
 *  slice: a failed slice is retried one text at a time, and only the texts that still fail
 *  come back as null with their error. */
export async function embed(texts: string[]): Promise<{ vectors: (number[] | null)[]; errors: string[] }> {
  const vectors: (number[] | null)[] = new Array(texts.length).fill(null);
  const errors: string[] = [];
  lastRequests = 0; lastTruncated = 0;
  const prepared = texts.map((t) => {
    if (EMBEDDING_MAX_CHARS && t.length > EMBEDDING_MAX_CHARS) { lastTruncated++; return t.slice(0, EMBEDDING_MAX_CHARS); }
    return t;
  });
  for (let i = 0; i < prepared.length; i += EMBEDDING_MAX_INPUTS) {
    const slice = prepared.slice(i, i + EMBEDDING_MAX_INPUTS);
    try {
      const vs = await embedOnce(slice); lastRequests++;
      vs.forEach((v, j) => vectors[i + j] = v);
    } catch (_e) {
      // Isolate: find which input the endpoint objects to, keep the rest.
      for (let j = 0; j < slice.length; j++) {
        try { vectors[i + j] = (await embedOnce([slice[j]]))[0]; lastRequests++; }
        catch (e2) { errors.push(`input ${i + j}: ${e2 instanceof Error ? e2.message : String(e2)}`); }
      }
    }
  }
  return { vectors, errors };
}

async function embedOnce(texts: string[]): Promise<number[][]> {
  if (!EMBEDDING_URL) throw new Error("EMBEDDING_URL is not set.");
  const res = await fetch(EMBEDDING_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(EMBEDDING_KEY ? { Authorization: `Bearer ${EMBEDDING_KEY}` } : {}),
    },
    body: JSON.stringify({ model: EMBEDDING_MODEL, input: texts,
      ...(EMBEDDING_TRUNCATE_TOKENS ? { truncate_prompt_tokens: EMBEDDING_TRUNCATE_TOKENS } : {}) }),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`The embeddings endpoint answered ${res.status}: ${text.slice(0, 300)}`);
  const data = JSON.parse(text);
  const vectors: number[][] = (data.data ?? []).map((d: any) => d.embedding);
  if (vectors.length !== texts.length) {
    throw new Error(`Got ${vectors.length} vectors for ${texts.length} texts.`);
  }
  const dim = vectors[0]?.length ?? 0;
  if (dim !== EMBEDDING_DIM) {
    throw new Error(
      `Model ${EMBEDDING_MODEL} returns dimension ${dim}, but EMBEDDING_DIM and the table are ${EMBEDDING_DIM}. ` +
      `Set EMBEDDING_DIM=${dim} and rebuild platform.embeddings with demo/platform_vector.sql before anything is filled.`,
    );
  }
  return vectors;
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  const batch = Math.min(Number(url.searchParams.get("batch") ?? "20"), 100);

  if (!EMBEDDING_URL) {
    return Response.json({
      status: "off",
      explanation:
        "EMBEDDING_URL is not set, so nothing is embedded. Set EMBEDDING_URL, EMBEDDING_KEY, " +
        "EMBEDDING_MODEL and EMBEDDING_DIM in the service's Environment. Keyword search is unaffected.",
    });
  }

  try {
    const candidates: Candidate[] = await rpc("embed_candidates", { max_rows: batch });
    if (!candidates.length) {
      return Response.json({ status: "done", embedded: 0, comment: "Nothing was waiting." });
    }

    const { vectors, errors: embedErrors } = await embed(candidates.map((c) => c.text));

    let saved = 0;
    const errors: string[] = embedErrors.map((m) => {
      const k = Number((m.match(/^input (\d+)/) || [])[1]); const c = candidates[k];
      return c ? `${c.source}/${c.id}: ${m.replace(/^input \d+: /, "")}` : m;
    });
    for (let i = 0; i < candidates.length; i++) {
      const c = candidates[i];
      if (!vectors[i]) continue; // failed upstream; already in errors
      try {
        await rpc("embed_save", {
          p_source: c.source,
          p_id: c.id,
          p_model: EMBEDDING_MODEL,
          p_vector: JSON.stringify(vectors[i]),
          p_text_hash: c.text_hash,
        });
        saved++;
      } catch (e) {
        errors.push(`${c.source}/${c.id}: ${e instanceof Error ? e.message : String(e)}`);
      }
    }

    return Response.json({
      status: "done",
      model: EMBEDDING_MODEL,
      dimension: EMBEDDING_DIM,
      requests: lastRequests,
      max_inputs_per_request: EMBEDDING_MAX_INPUTS,
      embedded: saved,
      truncated: lastTruncated,
      failed: errors.length,
      errors: errors.slice(0, 5),
      comment: saved === batch ? "Full batch -- run again to continue." : "Everything that was waiting is embedded.",
    });
  } catch (e) {
    return Response.json(
      { status: "error", message: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  }
});
