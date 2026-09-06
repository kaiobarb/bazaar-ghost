// deno-lint-ignore-file require-await
// Async fetch stubs intentionally return immediately without network access.
function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
Deno.env.set("SUPABASE_URL", "http://localhost:54321");
Deno.env.set("SUPABASE_SECRET_KEY", "test-only-key");
Deno.env.set("GITHUB_TOKEN", "test-only-token");
Deno.env.set("ENV", "dev");
const { dispatchProcessing } = await import("./processing.ts");
const plan = {
  vod_id: 1,
  source_id: "123",
  old_templates: false,
  profile: { crop_region: [0, 0, 1, 1] },
  chunks: Array.from(
    { length: 257 },
    (_, index) => ({ chunk_id: String(index), vod_id: 1, source_id: "123" }),
  ),
};

Deno.test("dispatch bounds matrices and includes only successfully queued rows", async () => {
  const original = globalThis.fetch;
  const sizes: number[] = [];
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    const body = JSON.parse(String(init?.body));
    if (url.host === "api.github.com") {
      assert(body.ref === "dev");
      sizes.push(JSON.parse(body.inputs.chunk_uuids).length);
      return new Response(null, { status: 204 });
    }
    assert(url.searchParams.get("status") === "eq.pending");
    const ids = url.searchParams.get("id")!.slice(4, -1).split(",");
    // Another caller already queued one row: it must not be dispatched twice.
    return Response.json(ids.filter((id) => id !== "0").map((id) => ({ id })));
  };
  try {
    const ids = await dispatchProcessing(plan);
    assert(ids.length === 256 && !ids.includes("0"));
    assert(JSON.stringify(sizes) === "[255,1]");
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test("failed GitHub dispatch rolls back only its own queued rows", async () => {
  const original = globalThis.fetch;
  let rolledBack = false;
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    if (url.host === "api.github.com") {
      return new Response("Unavailable", { status: 503 });
    }
    const body = JSON.parse(String(init?.body));
    if (body.status === "pending") {
      assert(url.searchParams.get("status") === "eq.queued");
      assert(url.searchParams.get("queued_at")?.startsWith("eq."));
      rolledBack = true;
      return Response.json([]);
    }
    return Response.json([{ id: "1" }]);
  };
  try {
    let failed = false;
    try {
      await dispatchProcessing(plan);
    } catch {
      failed = true;
    }
    assert(failed && rolledBack);
  } finally {
    globalThis.fetch = original;
  }
});
