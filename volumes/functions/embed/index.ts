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

/** Embeds a list of texts. Throws with the endpoint's own message. */
export async function embed(texts: string[]): Promise<number[][]> {
  if (!EMBEDDING_URL) throw new Error("EMBEDDING_URL is not set.");
  const res = await fetch(EMBEDDING_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(EMBEDDING_KEY ? { Authorization: `Bearer ${EMBEDDING_KEY}` } : {}),
    },
    body: JSON.stringify({ model: EMBEDDING_MODEL, input: texts }),
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

    const vectors = await embed(candidates.map((c) => c.text));

    let saved = 0;
    const errors: string[] = [];
    for (let i = 0; i < candidates.length; i++) {
      const c = candidates[i];
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
      embedded: saved,
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
