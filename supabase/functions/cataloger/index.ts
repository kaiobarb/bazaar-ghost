import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { getBazaarGameId } from "./lib/twitch.ts";
import { discoverStreamers } from "./handlers/discover-streamers.ts";
import { backfillBazaarVODs } from "./handlers/backfill-vods.ts";
import { fullRun } from "./handlers/full-run.ts";

serve(async (req) => {
  try {
    const url = new URL(req.url);
    const path = url.pathname.split("/").pop();

    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    let result;

    switch (path) {
      case "discover-streamers": {
        const gameId = await getBazaarGameId();
        result = await discoverStreamers(gameId);
        break;
      }

      case "backfill-bazaar-vods": {
        result = await backfillBazaarVODs();
        break;
      }

      case "full-run": {
        result = await fullRun();
        break;
      }

      default:
        return new Response("Not found", { status: 404 });
    }

    return new Response(JSON.stringify(result), {
      headers: { "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error) {
    console.error("Cataloger error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { "Content-Type": "application/json" },
      status: 500,
    });
  }
});