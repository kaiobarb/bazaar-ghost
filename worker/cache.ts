/** Cache only public reads. Credentials never participate in these read contracts. */
export async function publicCache(
  request: Request,
  env: Env,
  load: () => Promise<Response>,
  postBody = "",
): Promise<Response> {
  if (env.ENVIRONMENT === "local") return load();
  const url = new URL(request.url);
  if (request.method === "POST") {
    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(postBody),
    );
    url.searchParams.set(
      "body",
      Array.from(new Uint8Array(digest), (b) =>
        b.toString(16).padStart(2, "0"),
      ).join(""),
    );
  }
  // Response shape and pagination vary by these headers in the compatibility API.
  for (const name of ["accept", "range", "prefer"]) {
    url.searchParams.set(`header-${name}`, request.headers.get(name) || "");
  }
  url.pathname = `/__public_cache${url.pathname}`;
  const key = new Request(url, { method: "GET" });
  try {
    const hit = await caches.default.match(key);
    if (hit) return hit;
  } catch (error) {
    console.warn("Public cache read failed", String(error));
  }
  const response = await load();
  if (response.status !== 200) return response;
  const result = new Response(response.body, response);
  result.headers.set("Cache-Control", "public,max-age=30");
  try {
    await caches.default.put(key, result.clone());
  } catch (error) {
    console.warn("Public cache write failed", String(error));
  }
  return result;
}
