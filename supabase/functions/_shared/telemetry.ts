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

// Map log levels to OTLP severity numbers
const SEVERITY_MAP: Record<LogLevel, { text: string; number: number }> = {
  info: { text: "INFO", number: 9 },
  warn: { text: "WARN", number: 13 },
  error: { text: "ERROR", number: 17 },
};

/**
 * Structured JSON logging for Grafana Loki via OTLP.
 * Pushes logs directly to Grafana Cloud OTLP endpoint AND writes to console.
 * The service name defaults to "process-vod" but can be overridden via attributes.
 */
export async function log(
  level: LogLevel,
  message: string,
  attributes: Record<string, unknown> = {},
): Promise<void> {
  const serviceName = typeof attributes.service === "string"
    ? attributes.service
    : "process-vod";

  const logEntry = {
    timestamp: new Date().toISOString(),
    level,
    service: serviceName,
    message,
    ...attributes,
  };

  // Always write to console (Supabase function logs)
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

  // Push to Grafana Loki via OTLP
  if (!OTEL_ENDPOINT) return;

  const now = Date.now() * 1_000_000; // nanoseconds
  const severity = SEVERITY_MAP[level];

  // Build OTLP log attributes from all non-reserved keys
  const otlpAttributes = Object.entries(attributes)
    .filter(([key]) => key !== "service")
    .map(([key, val]) => ({
      key,
      value: { stringValue: String(val) },
    }));

  const payload = {
    resourceLogs: [
      {
        resource: {
          attributes: [
            { key: "service.name", value: { stringValue: serviceName } },
          ],
        },
        scopeLogs: [
          {
            scope: { name: serviceName },
            logRecords: [
              {
                timeUnixNano: now.toString(),
                observedTimeUnixNano: now.toString(),
                severityNumber: severity.number,
                severityText: severity.text,
                body: { stringValue: message },
                attributes: otlpAttributes,
              },
            ],
          },
        ],
      },
    ],
  };

  try {
    const headers = parseOtelHeaders();
    const response = await fetch(`${OTEL_ENDPOINT}/v1/logs`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...headers,
      },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error(`[telemetry] Failed to push log: ${response.status} ${errorText}`);
    }
  } catch (error) {
    console.error("[telemetry] Error pushing log:", error);
  }
}
