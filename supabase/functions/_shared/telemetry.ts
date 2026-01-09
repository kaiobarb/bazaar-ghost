/**
 * Simple OpenTelemetry metrics and structured logging for Supabase Edge Functions.
 * Pushes metrics to Grafana Cloud OTLP endpoint.
 */

const OTEL_ENDPOINT = Deno.env.get("OTEL_EXPORTER_OTLP_ENDPOINT");
const OTEL_HEADERS = Deno.env.get("OTEL_EXPORTER_OTLP_HEADERS"); // URL-encoded

// Parse the URL-encoded headers into a usable format
function parseOtelHeaders(): Record<string, string> {
  if (!OTEL_HEADERS) return {};

  const headers: Record<string, string> = {};
  const decoded = decodeURIComponent(OTEL_HEADERS);

  // Format is "Key=Value" pairs separated by commas
  for (const pair of decoded.split(",")) {
    const [key, ...valueParts] = pair.split("=");
    if (key && valueParts.length > 0) {
      headers[key.trim()] = valueParts.join("=").trim();
    }
  }

  return headers;
}

/**
 * Push a counter metric to Grafana OTLP endpoint.
 * Non-blocking - logs errors but doesn't throw.
 */
export async function recordCounter(
  name: string,
  value: number = 1,
  attributes: Record<string, string> = {},
): Promise<void> {
  if (!OTEL_ENDPOINT) {
    console.log(`[telemetry] OTEL_ENDPOINT not set, skipping metric: ${name}`);
    return;
  }

  const now = Date.now() * 1_000_000; // nanoseconds

  // Build OTLP metrics payload
  const payload = {
    resourceMetrics: [
      {
        resource: {
          attributes: [
            { key: "service.name", value: { stringValue: "process-vod" } },
          ],
        },
        scopeMetrics: [
          {
            scope: { name: "eventsub" },
            metrics: [
              {
                name,
                sum: {
                  dataPoints: [
                    {
                      asInt: value.toString(),
                      startTimeUnixNano: now.toString(),
                      timeUnixNano: now.toString(),
                      attributes: Object.entries(attributes).map(
                        ([key, val]) => ({
                          key,
                          value: { stringValue: val },
                        }),
                      ),
                    },
                  ],
                  aggregationTemporality: 2, // DELTA
                  isMonotonic: true,
                },
              },
            ],
          },
        ],
      },
    ],
  };

  try {
    const headers = parseOtelHeaders();
    const response = await fetch(`${OTEL_ENDPOINT}/v1/metrics`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...headers,
      },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error(`[telemetry] Failed to push metric ${name}: ${response.status} ${errorText}`);
    }
  } catch (error) {
    console.error(`[telemetry] Error pushing metric ${name}:`, error);
  }
}

/**
 * Push a histogram/gauge metric to Grafana OTLP endpoint.
 * Non-blocking - logs errors but doesn't throw.
 */
export async function recordHistogram(
  name: string,
  value: number,
  attributes: Record<string, string> = {},
): Promise<void> {
  if (!OTEL_ENDPOINT) {
    console.log(`[telemetry] OTEL_ENDPOINT not set, skipping metric: ${name}`);
    return;
  }

  const now = Date.now() * 1_000_000; // nanoseconds

  const payload = {
    resourceMetrics: [
      {
        resource: {
          attributes: [
            { key: "service.name", value: { stringValue: "process-vod" } },
          ],
        },
        scopeMetrics: [
          {
            scope: { name: "eventsub" },
            metrics: [
              {
                name,
                gauge: {
                  dataPoints: [
                    {
                      asDouble: value,
                      timeUnixNano: now.toString(),
                      attributes: Object.entries(attributes).map(
                        ([key, val]) => ({
                          key,
                          value: { stringValue: val },
                        }),
                      ),
                    },
                  ],
                },
              },
            ],
          },
        ],
      },
    ],
  };

  try {
    const headers = parseOtelHeaders();
    const response = await fetch(`${OTEL_ENDPOINT}/v1/metrics`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...headers,
      },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error(`[telemetry] Failed to push histogram ${name}: ${response.status} ${errorText}`);
    }
  } catch (error) {
    console.error(`[telemetry] Error pushing histogram ${name}:`, error);
  }
}

type LogLevel = "info" | "warn" | "error";

/**
 * Structured JSON logging for Grafana Loki.
 * Output format is compatible with Loki's JSON parser.
 */
export function log(
  level: LogLevel,
  message: string,
  attributes: Record<string, unknown> = {},
): void {
  const logEntry = {
    timestamp: new Date().toISOString(),
    level,
    service: "process-vod",
    message,
    ...attributes,
  };

  // Use appropriate console method based on level
  switch (level) {
    case "error":
      console.error(JSON.stringify(logEntry));
      break;
    case "warn":
      console.warn(JSON.stringify(logEntry));
      break;
    default:
      console.log(JSON.stringify(logEntry));
  }
}
