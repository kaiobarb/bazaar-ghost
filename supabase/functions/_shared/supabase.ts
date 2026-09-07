import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getBazaarGameId, getStreamerVodsWithChapters } from "./twitch.ts";

import { hasSecretKey } from "./auth.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SECRET_KEY = Deno.env.get("SUPABASE_SECRET_KEY") ||
  Deno.env.get("SECRET_KEY");
const CLIENT_KEY = SECRET_KEY || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

export const supabase = createClient(SUPABASE_URL, CLIENT_KEY);

export function verifySecretKey(req: Request): boolean {
  return hasSecretKey(
    req,
    SECRET_KEY || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
  );
}

export { extractBazaarChapters } from "./chapters.ts";
import { extractBazaarChapters } from "./chapters.ts";

export interface FetchAndUpsertResult {
  /** Number of VODs with Bazaar gameplay that were upserted */
  vodsUpserted: number;
  /** Total Bazaar segment count across all upserted VODs */
  bazaarSegments: number;
  /** Source IDs of upserted VODs */
  upsertedVodIds: string[];
  /** Total VODs fetched from Twitch (before filtering for Bazaar) */
  totalVodsFetched: number;
  /** Oldest VOD timestamp (for streamer stats) */
  oldestVod: string | null;
}

export interface StreamerIdentity {
  id: number;
  login: string;
  display_name?: string | null;
  profile_image_url?: string | null;
}

interface StoredStreamerIdentity {
  login?: string | null;
  display_name?: string | null;
  profile_image_url?: string | null;
}

/**
 * Keep mutable Twitch identity fields fresh while preserving the immutable
 * streamer ID and per-streamer processing config.
 */
export async function syncStreamerIdentity(
  identity: StreamerIdentity,
  current?: StoredStreamerIdentity | null,
): Promise<boolean> {
  const login = identity.login.toLowerCase();
  const updates: Record<string, string> = {};

  if (current?.login !== login) {
    updates.login = login;
  }

  if (
    identity.display_name &&
    current?.display_name !== identity.display_name
  ) {
    updates.display_name = identity.display_name;
  }

  if (
    identity.profile_image_url &&
    current?.profile_image_url !== identity.profile_image_url
  ) {
    updates.profile_image_url = identity.profile_image_url;
  }

  if (Object.keys(updates).length === 0) {
    return false;
  }

  updates.updated_at = new Date().toISOString();

  const { error } = await supabase
    .from("streamers")
    .update(updates)
    .eq("id", identity.id);

  if (error) {
    console.error(
      `Failed to sync streamer identity for ${identity.id}:`,
      error,
    );
    return false;
  }

  console.log(
    `Synced streamer identity for ${identity.id}: ${login}`,
  );
  return true;
}

/**
 * Fetch VODs with chapter data, extract Bazaar chapters, and upsert to database.
 *
 * @param streamerId - Internal streamer ID from database
 * @param streamerLogin - Twitch login name
 * @param numVods - Optional limit on number of VODs to fetch. If not provided, fetches all.
 * @param skipLiveVod - If true, skip the most recent VOD
 */
export async function fetchAndUpsertVods(
  streamerId: number,
  streamerLogin: string,
  numVods?: number,
  skipLiveVod: boolean = false,
  dryRun: boolean = false,
): Promise<FetchAndUpsertResult> {
  const bazaarGameId = await getBazaarGameId();
  const vods = await getStreamerVodsWithChapters(streamerLogin, numVods);

  let vodsUpserted = 0;
  let bazaarSegments = 0;
  const upsertedVodIds: string[] = [];

  // Optionally skip first VOD if streamer is live
  const vodsToProcess = skipLiveVod && vods.length > 0 ? vods.slice(1) : vods;
  const totalVodsFetched = vodsToProcess.length;

  // Calculate oldest VOD timestamp
  let oldestVod: string | null = null;
  if (vodsToProcess.length > 0) {
    oldestVod = vodsToProcess.reduce((oldest, vod) => {
      return !oldest || vod.publishedAt < oldest ? vod.publishedAt : oldest;
    }, null as string | null);
  }

  for (const vod of vodsToProcess) {
    console.log(`Processing VOD ${vod.id}: ${vod.title}`);

    // Extract Bazaar chapter time ranges
    let chapters = extractBazaarChapters(
      vod.chapters,
      vod.lengthSeconds,
      bazaarGameId,
    );

    // Fallback: If no chapters found but VOD's main game is The Bazaar,
    // treat the entire VOD as a Bazaar segment
    if (chapters.length === 0 && vod.chapters.length === 0) {
      const isBazaarGame = vod.game?.id === bazaarGameId ||
        vod.game?.name?.toLowerCase() === "the bazaar";

      if (isBazaarGame) {
        console.log(
          `  No chapters, but VOD game is The Bazaar - treating entire VOD as Bazaar segment`,
        );
        chapters = [0, vod.lengthSeconds];
      } else {
        console.log(`  No Bazaar gameplay found in VOD ${vod.id}, skipping`);
        continue;
      }
    }

    if (chapters.length === 0 || vod.lengthSeconds <= 0) continue;
    if (dryRun) {
      vodsUpserted++;
      bazaarSegments += chapters.length / 2;
      upsertedVodIds.push(vod.id);
      continue;
    }

    // Upsert VOD to database
    const { error } = await supabase.from("vods").upsert(
      {
        streamer_id: streamerId,
        source: "twitch",
        source_id: vod.id,
        title: vod.title,
        duration_seconds: vod.lengthSeconds,
        published_at: vod.publishedAt,
        bazaar_chapters: chapters,
        availability: "available",
        unavailable_since: null,
        last_availability_check: new Date().toISOString(),
        ready_for_processing: true,
        updated_at: new Date().toISOString(),
      },
      {
        onConflict: "source,source_id",
        ignoreDuplicates: false,
      },
    );

    if (error) {
      throw new Error(`Failed to save VOD ${vod.id}: ${error.message}`);
    } else {
      vodsUpserted++;
      bazaarSegments += chapters.length / 2;
      upsertedVodIds.push(vod.id);
      console.log(`✓ Upserted VOD ${vod.id} with Bazaar chapters`);
    }
  }

  return {
    vodsUpserted,
    bazaarSegments,
    upsertedVodIds,
    totalVodsFetched,
    oldestVod,
  };
}
