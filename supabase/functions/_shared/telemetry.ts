/** Optional OTLP export. Telemetry failures never change processing outcomes. */
const endpoint = Deno.env.get("OTEL_EXPORTER_OTLP_ENDPOINT")?.replace(
  /\/$/,
  "",
);
const service = Deno.env.get("OTEL_SERVICE_NAME") || "bazaarghost-control";
type LogLevel = "info" | "warn" | "error";

function attributes(values: Record<string, unknown>): unknown[] {
  return Object.entries(values).filter(([, value]) => value != null).map((
    [key, value],
  ) => ({
    key,
    value: typeof value === "number"
      ? { doubleValue: value }
      : typeof value === "boolean"
      ? { boolValue: value }
      : {
        stringValue: typeof value === "string" ? value : JSON.stringify(value),
      },
  }));
}

async function send(signal: string, payload: unknown): Promise<void> {
  if (!endpoint) return;
  try {
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
    };
    for (
      const pair of (Deno.env.get("OTEL_EXPORTER_OTLP_HEADERS") || "").split(
        ",",
      )
    ) {
      const separator = pair.indexOf("=");
      if (separator > 0) {
        headers[pair.slice(0, separator).trim()] = decodeURIComponent(
          pair.slice(separator + 1).trim(),
        );
      }
    }
    const response = await fetch(`${endpoint}/v1/${signal}`, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) {
      console.error(`OTLP ${signal} export failed: ${response.status}`);
    }
    await response.body?.cancel();
  } catch (error: any) {
    console.error(`OTLP ${signal} export failed:`, error.message);
  }
}

function exportPayload(signal: string, payload: unknown): Promise<void> {
  const pending = send(signal, payload);
  const runtime = (globalThis as unknown as {
    EdgeRuntime?: { waitUntil: (promise: Promise<void>) => void };
  }).EdgeRuntime;
  runtime?.waitUntil(pending);
  return pending;
}

function metric(
  name: string,
  value: number,
  labels: Record<string, string>,
  histogram: boolean,
): Promise<void> {
  if (!endpoint || !Number.isFinite(value)) return Promise.resolve();
  const now = BigInt(Date.now()) * 1_000_000n;
  const point = {
    startTimeUnixNano: (now - 1_000_000n).toString(),
    timeUnixNano: now.toString(),
    attributes: attributes(labels),
  };
  const data = histogram
    ? {
      histogram: {
        aggregationTemporality: 1,
        dataPoints: [{
          ...point,
          count: "1",
          sum: value,
          bucketCounts: ["1"],
          explicitBounds: [],
        }],
      },
    }
    : {
      sum: {
        aggregationTemporality: 1,
        isMonotonic: true,
        dataPoints: [{ ...point, asDouble: value }],
      },
    };
  return exportPayload("metrics", {
    resourceMetrics: [{
      resource: { attributes: attributes({ "service.name": service }) },
      scopeMetrics: [{
        scope: { name: "bazaarghost" },
        metrics: [{ name, ...data }],
      }],
    }],
  });
}

export function recordCounter(
  name: string,
  value = 1,
  labels: Record<string, string> = {},
): Promise<void> {
  return value < 0 ? Promise.resolve() : metric(name, value, labels, false);
}

export function recordHistogram(
  name: string,
  value: number,
  labels: Record<string, string> = {},
): Promise<void> {
  return metric(name, value, labels, true);
}

export function log(
  level: LogLevel,
  message: string,
  labels: Record<string, unknown> = {},
): Promise<void> {
  console[level](
    JSON.stringify({
      timestamp: new Date().toISOString(),
      level,
      message,
      ...labels,
    }),
  );
  if (!endpoint) return Promise.resolve();
  const severity = { info: 9, warn: 13, error: 17 }[level];
  return exportPayload("logs", {
    resourceLogs: [{
      resource: {
        attributes: attributes({ "service.name": labels.service || service }),
      },
      scopeLogs: [{
        scope: { name: "bazaarghost" },
        logRecords: [{
          timeUnixNano: (BigInt(Date.now()) * 1_000_000n).toString(),
          severityNumber: severity,
          severityText: level.toUpperCase(),
          body: { stringValue: message },
          attributes: attributes(labels),
        }],
      }],
    }],
  });
}
