// deno-lint-ignore-file require-await
// Async fetch stubs intentionally return immediately without network access.
Deno.env.set("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318");
const { recordCounter, recordHistogram } = await import("./telemetry.ts?test");

Deno.test("OTLP uses delta counters and real histograms; export failure stays optional", async () => {
  const original = globalThis.fetch;
  const payloads: Record<string, any>[] = [];
  globalThis.fetch = async (_input, init) => {
    payloads.push(JSON.parse(String(init?.body)));
    return new Response(null, { status: 204 });
  };
  try {
    await recordCounter("chunks", 1);
    await recordHistogram("duration", 123);
    const metrics = payloads.map((payload) =>
      payload.resourceMetrics[0].scopeMetrics[0].metrics[0]
    );
    if (
      metrics[0].sum.aggregationTemporality !== 1 ||
      metrics[1].histogram.dataPoints[0].sum !== 123
    ) {
      throw new Error("Incorrect metric encoding");
    }
    globalThis.fetch = async () => {
      throw new Error("collector unavailable");
    };
    await recordCounter("chunks", 1);
  } finally {
    globalThis.fetch = original;
  }
});
