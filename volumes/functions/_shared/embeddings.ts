// One reading of EMBEDDING_URL, for every function that sends text to an embedder.
//
// An OpenAI-compatible base URL comes in three shapes and all three were pasted
// into a panel here (2026-09-16): the host on its own, the host with /v1, and
// the complete path. The first two answer 404, which reaches the store as "the
// endpoint answered 404" and nothing about why. So normalise instead.
//
// This lived in embed only, and skillhub passed the same variable to fetch
// untouched — so a base URL indexed perfectly and then failed every search
// (2026-09-18). Two functions disagreeing about what one setting means is not a
// thing configuration can fix; it is one function, imported twice.

/** The embeddings endpoint, from a host, a base URL, or the endpoint itself. */
export function embeddingsEndpoint(raw: string): string {
  const u = raw.trim().replace(/\/+$/, "");
  if (!u) return "";
  if (/\/embeddings$/.test(u)) return u;          // already the endpoint
  if (/\/v\d+$/.test(u)) return `${u}/embeddings`; // the usual "base URL"
  try {                                           // the host on its own
    if (new URL(u).pathname === "/") return `${u}/v1/embeddings`;
  } catch { /* not a URL we can parse; leave it to the fetch to complain */ }
  return u;                                       // some other path: assume it was meant
}

/** The endpoint as configured in this deployment, already normalised. */
export function configuredEmbeddingsEndpoint(): string {
  return embeddingsEndpoint(Deno.env.get("EMBEDDING_URL") ?? "");
}
