import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET_KEY = Deno.env.get("SECRET_KEY");

// Debug logging to see what environment variables we have
console.log("SUPABASE_URL:", SUPABASE_URL);
console.log(
  "SUPABASE_SERVICE_ROLE_KEY:",
  SUPABASE_SERVICE_ROLE_KEY
    ? `${SUPABASE_SERVICE_ROLE_KEY.substring(0, 20)}...`
    : "NOT SET",
);
console.log(
  "SECRET_KEY:",
  SECRET_KEY ? `${SECRET_KEY.substring(0, 20)}...` : "NOT SET",
);

export const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

/**
 * Verifies that the request contains a valid secret key in the apikey header
 * Returns true if valid, false otherwise
 * Skips verification for local development and Supabase UI test invocations
 */
export function verifySecretKey(req: Request): boolean {
  // Skip verification on local (kong:8000 is the internal Docker URL for local dev)
  const isLocal = SUPABASE_URL.includes("localhost") ||
    SUPABASE_URL.includes("127.0.0.1") ||
    SUPABASE_URL.includes("kong:8000");

  console.log(SUPABASE_URL);
  if (isLocal) {
    console.log("Skipped secret verification (local environment)");
    return true;
  }

  const apiKey = req.headers.get("apikey");

  if (!apiKey) {
    console.log("No apikey header provided");
    return false;
  }

  if (!SECRET_KEY) {
    console.error("SECRET_KEY environment variable not set");
    return false;
  }

  const isValid = apiKey === SECRET_KEY;

  if (!isValid) {
    console.log("Invalid apikey provided");
  }

  return isValid;
}
