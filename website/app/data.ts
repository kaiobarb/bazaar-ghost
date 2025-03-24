import { createClient } from "@supabase/supabase-js";
import { Database } from "./supabase";

const supabase = createClient<Database>(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE!
);

const MAX_PAGE_SIZE = 100;

export const fetchMatchups = async (
  usernameQuery: string,
  streamer?: string,
  page: number = 1,
  pageSize: number = 20 // Default to 20 results per page
) => {
  pageSize = Math.min(MAX_PAGE_SIZE, pageSize);
  const from = (page - 1) * pageSize; // Start index
  const to = from + pageSize - 1; // End index

  let query = supabase
    .from("matchups")
    .select(
      `id, vod_id, username, vod_link, rank, frame_time, 
           vods!inner(streamer_id, streamers!inner(name, profile_image_url, display_name))`,
      { count: "exact" } // Count total records for pagination
    )
    .ilike("username", `%${usernameQuery}%`)
    .range(from, to);

  if (streamer) {
    query = query.ilike("vods.streamers.name", `%${streamer}%`);
  }

  const { data, error, count } = await query;

  if (error) {
    throw error;
  }

  return {
    matchups: data,
    total: count ?? 0, // Total number of results
    page,
    pageSize,
    totalPages: Math.ceil((count ?? 0) / pageSize),
  };
};
