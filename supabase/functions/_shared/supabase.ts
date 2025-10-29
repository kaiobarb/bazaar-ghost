import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_SECRET_KEY = Deno.env.get("SUPABASE_SECRET_KEY");

// Debug logging to see what environment variables we have
console.log("SUPABASE_URL:", SUPABASE_URL);
console.log("SUPABASE_SERVICE_ROLE_KEY:", SUPABASE_SERVICE_ROLE_KEY ? `${SUPABASE_SERVICE_ROLE_KEY.substring(0, 20)}...` : "NOT SET");
console.log("SUPABASE_SECRET_KEY:", SUPABASE_SECRET_KEY ? `${SUPABASE_SECRET_KEY.substring(0, 20)}...` : "NOT SET");

export const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

/**
 * Verifies that the request contains a valid secret key in the apikey header
 * Returns true if valid, false otherwise
 */
export function verifySecretKey(req: Request): boolean {
  const apiKey = req.headers.get("apikey");

  if (!apiKey) {
    console.log("No apikey header provided");
    return false;
  }

  if (!SUPABASE_SECRET_KEY) {
    console.error("SUPABASE_SECRET_KEY environment variable not set");
    return false;
  }

  const isValid = apiKey === SUPABASE_SECRET_KEY;

  if (!isValid) {
    console.log("Invalid apikey provided");
  }

  return isValid;
}