import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

// Initialize Supabase client (server-side)
const supabase = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE!
);

export async function GET(req: Request) {
  try {
    // Extract username from query params
    const { searchParams } = new URL(req.url);
    const username = searchParams.get("username");

    if (!username) {
      return NextResponse.json(
        { error: "Username is required" },
        { status: 400 }
      );
    }

    // Query Supabase for matchups
    const { data, error } = await supabase
      .from("matchups")
      .select(
        "vod_id, frame_time, username, confidence, image_url, vod_link, rank"
      )
      .ilike("username", `%${username}%`); // Case-insensitive search

    if (error) {
      throw error;
    }

    return NextResponse.json({ matchups: data });
  } catch (error) {
    return NextResponse.json(
      { error: "Failed to fetch matchups", details: (error as Error).message },
      { status: 500 }
    );
  }
}
