import { decodeRow, integer, requireValue, rows } from "./http";

/** pg_trgm-style unique, word-padded trigrams; punctuation separates words. */
export function trigrams(value: string): string[] {
  const grams = new Set<string>();
  for (const word of value.toLowerCase().match(/[\p{L}\p{N}]+/gu) || []) {
    const chars = Array.from(`  ${word} `);
    for (let i = 0; i < chars.length - 2; i++)
      grams.add(chars.slice(i, i + 3).join(""));
  }
  return [...grams].sort();
}
export async function search(env: Env, input: Record<string, any>) {
  const query = input.search_query ?? "";
  requireValue(
    typeof query === "string" && query.length <= 128,
    "Search must be at most 128 characters",
  );
  const limit = integer(input.result_limit ?? 100, "result_limit", 1, 100),
    offset = integer(input.result_offset ?? 0, "result_offset", 0, 100_000);
  const threshold = input.similarity_threshold ?? 0.2;
  requireValue(
    typeof threshold === "number" && threshold >= 0 && threshold <= 1,
    "Invalid similarity threshold",
  );
  const days: Record<string, number> = {
    all: 0,
    day: 1,
    week: 7,
    month: 30,
    year: 365,
  };
  const range = input.date_range_filter ?? "all";
  requireValue(Object.hasOwn(days, range), "Invalid date range");
  const clauses: string[] = [],
    params: unknown[] = [];
  let cte = "",
    join = "",
    score = "1.0";
  if (query && threshold > 0) {
    const grams = trigrams(query);
    if (!grams.length) return [];
    // json_each uses one binding even for long names. Posting index avoids scanning detections.
    cte = `WITH candidates AS (SELECT g.name,1.0*count(*)/(?+n.gram_count-count(*)) AS score FROM search_grams g JOIN search_names n ON n.name=g.name WHERE g.gram IN(SELECT value FROM json_each(?)) GROUP BY g.name HAVING 1.0*count(*)/(?+n.gram_count-count(*))>=?)`;
    params.push(grams.length, JSON.stringify(grams), grams.length, threshold);
    join = "JOIN candidates c ON c.name=ds.username_lower";
    score = "c.score";
  } else if (query) {
    const grams = trigrams(query);
    cte = `WITH candidates AS (SELECT n.name,coalesce(1.0*count(g.gram)/nullif(?+n.gram_count-count(g.gram),0),0) AS score FROM search_names n LEFT JOIN search_grams g ON g.name=n.name AND g.gram IN(SELECT value FROM json_each(?)) GROUP BY n.name)`;
    params.push(grams.length, JSON.stringify(grams));
    join = "JOIN candidates c ON c.name=ds.username_lower";
    score = "c.score";
  }
  if (input.streamer_id_filter != null) {
    clauses.push("ds.streamer_id=?");
    params.push(integer(input.streamer_id_filter, "streamer_id_filter", 1));
  }
  if (input.vod_source_id_filter != null) {
    requireValue(
      /^\d+$/.test(input.vod_source_id_filter),
      "Invalid VOD filter",
    );
    clauses.push("ds.vod_source_id=?");
    params.push(String(input.vod_source_id_filter));
  }
  if (days[range]) {
    clauses.push("ds.actual_timestamp>=?");
    params.push(new Date(Date.now() - days[range] * 86400_000).toISOString());
  }
  const result = await rows(
    env,
    `${cte} SELECT ds.*,${score} AS similarity_score,count(*) OVER() AS total_count FROM detection_search ds ${join} ${clauses.length ? "WHERE " + clauses.join(" AND ") : ""} ORDER BY similarity_score DESC,actual_timestamp DESC,detection_id LIMIT ? OFFSET ?`,
    ...params,
    limit,
    offset,
  );
  return result.map(({ username_lower, ...row }) => decodeRow(row));
}
