// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GITHUB_TOKEN = Deno.env.get("GITHUB_TOKEN")!;
const GITHUB_REPO = "bazaar-ghost";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

interface TriggerGithubProcessingRequest {
  force?: boolean; // Force trigger even if no pending chunks
  priority_min?: number; // Minimum priority level to consider
  vod_id?: number; // Process all chunks from this VOD
  chunks_to_process?: number; // Number of chunks being processed (for logging)
}

interface TriggerGithubProcessingResponse {
  success: boolean;
  chunk_id?: string;
  vod_id?: number;
  chunks_triggered?: number;
  message: string;
  github_run_url?: string;
}

async function triggerGithubWorkflowForChunk(chunkId: string): Promise<string | null> {
  const workflowDispatchUrl = `https://api.github.com/repos/kaiobarb/${GITHUB_REPO}/actions/workflows/process-chunk.yml/dispatches`;

  const response = await fetch(workflowDispatchUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${GITHUB_TOKEN}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      ref: "main", // Branch to run workflow on
      inputs: {
        chunk_id: chunkId,
      },
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error(
      `GitHub workflow dispatch failed: ${response.status} ${response.statusText}`,
      errorText
    );
    throw new Error(
      `GitHub API error: ${response.status} ${response.statusText}`
    );
  }

  // GitHub API returns 204 No Content on success
  // We can't get the run URL directly, but we can construct the Actions page URL
  const actionsUrl = `https://github.com/kaiobarb/${GITHUB_REPO}/actions/workflows/process-chunk.yml`;
  return actionsUrl;
}

async function triggerGithubWorkflowForVod(vodId: number, chunkUuids: string[]): Promise<string | null> {
  const workflowDispatchUrl = `https://api.github.com/repos/kaiobarb/${GITHUB_REPO}/actions/workflows/process-vod.yml/dispatches`;

  const response = await fetch(workflowDispatchUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${GITHUB_TOKEN}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      ref: "main", // Branch to run workflow on
      inputs: {
        vod_id: vodId.toString(),
        chunk_uuids: JSON.stringify(chunkUuids),
      },
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error(
      `GitHub VOD workflow dispatch failed: ${response.status} ${response.statusText}`,
      errorText
    );
    throw new Error(
      `GitHub API error: ${response.status} ${response.statusText}`
    );
  }

  // GitHub API returns 204 No Content on success
  const actionsUrl = `https://github.com/kaiobarb/${GITHUB_REPO}/actions/workflows/process-vod.yml`;
  return actionsUrl;
}

async function findNextPendingChunk(priorityMin: number = 0) {
  const { data: chunks, error } = await supabase
    .from("chunks")
    .select(
      `
      id,
      vod_id,
      start_seconds,
      end_seconds,
      chunk_index,
      priority,
      vods(
        source_id,
        title,
        streamers(login, display_name)
      )
    `
    )
    .eq("status", "pending")
    .gte("priority", priorityMin)
    .order("priority", { ascending: false })
    .order("scheduled_for", { ascending: true })
    .limit(1);

  if (error) {
    console.error("Error fetching pending chunks:", error);
    throw new Error(`Database error: ${error.message}`);
  }

  return chunks.length > 0 ? chunks[0] : null;
}

async function markChunkAsQueued(chunkId: string) {
  const { error } = await supabase
    .from("chunks")
    .update({
      status: "queued",
      queued_at: new Date().toISOString(),
    })
    .eq("id", chunkId);

  if (error) {
    console.error("Error marking chunk as queued:", error);
    throw new Error(`Failed to update chunk status: ${error.message}`);
  }
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const requestBody: TriggerGithubProcessingRequest = await req
      .json()
      .catch(() => ({}));
    const { force = false, priority_min = 0, vod_id, chunks_to_process } = requestBody;

    console.log(
      `Triggering GitHub processing. Force: ${force}, Priority min: ${priority_min}, VOD ID: ${vod_id}`
    );

    // If VOD ID is provided, trigger batch processing for all queued chunks
    if (vod_id) {
      console.log(`Processing VOD ${vod_id} with ${chunks_to_process || 'unknown'} chunks`);

      // Get all queued chunks for this VOD
      const { data: vodChunks, error: vodError } = await supabase
        .from("chunks")
        .select("id, chunk_index")
        .eq("vod_id", vod_id)
        .eq("status", "queued")
        .order("chunk_index");

      if (vodError) {
        throw new Error(`Failed to fetch VOD chunks: ${vodError.message}`);
      }

      if (!vodChunks || vodChunks.length === 0) {
        const response: TriggerGithubProcessingResponse = {
          success: false,
          vod_id,
          message: `No queued chunks found for VOD ${vod_id}`,
        };
        return new Response(JSON.stringify(response), {
          headers: { "Content-Type": "application/json" },
          status: 404,
        });
      }

      // Get VOD details
      const { data: vod, error: vodDetailError } = await supabase
        .from("vods")
        .select(`
          source_id,
          title,
          streamers!inner(login, display_name)
        `)
        .eq("id", vod_id)
        .single();

      if (vodDetailError) {
        console.error("Failed to fetch VOD details:", vodDetailError);
      }

      // Extract chunk UUIDs
      const chunkUuids = vodChunks.map(c => c.id);

      console.log(
        `Triggering GitHub workflow for VOD ${vod?.source_id} by ${vod?.streamers?.login} with ${chunkUuids.length} chunks`
      );

      // Trigger GitHub workflow for entire VOD
      const githubRunUrl = await triggerGithubWorkflowForVod(vod_id, chunkUuids);

      console.log(`Successfully triggered GitHub workflow for VOD ${vod_id}`);

      const response: TriggerGithubProcessingResponse = {
        success: true,
        vod_id,
        chunks_triggered: chunkUuids.length,
        message: `Successfully triggered processing for VOD ${vod?.source_id} with ${chunkUuids.length} chunks`,
        github_run_url: githubRunUrl || undefined,
      };

      return new Response(JSON.stringify(response), {
        headers: { "Content-Type": "application/json" },
        status: 200,
      });
    }

    // Original single-chunk processing logic for backward compatibility
    console.log("No VOD ID provided, falling back to single chunk processing");

    // Find next pending chunk
    const chunk = await findNextPendingChunk(priority_min);

    if (!chunk && !force) {
      const response: TriggerGithubProcessingResponse = {
        success: true,
        message: "No pending chunks found",
      };
      return new Response(JSON.stringify(response), {
        headers: { "Content-Type": "application/json" },
        status: 200,
      });
    }

    if (!chunk) {
      const response: TriggerGithubProcessingResponse = {
        success: false,
        message: "No pending chunks found and force=false",
      };
      return new Response(JSON.stringify(response), {
        headers: { "Content-Type": "application/json" },
        status: 404,
      });
    }

    const vodInfo = chunk.vods as any;
    console.log(
      `Found chunk ${chunk.id} for VOD ${vodInfo?.source_id} by ${vodInfo?.streamers?.login}`
    );

    // Mark chunk as queued before triggering GitHub
    await markChunkAsQueued(chunk.id);

    // Trigger GitHub workflow
    const githubRunUrl = await triggerGithubWorkflowForChunk(chunk.id);

    console.log(`Successfully triggered GitHub workflow for chunk ${chunk.id}`);

    const response: TriggerGithubProcessingResponse = {
      success: true,
      chunk_id: chunk.id,
      message: `Successfully triggered processing for chunk ${chunk.chunk_index} of VOD ${vodInfo?.source_id}`,
      github_run_url: githubRunUrl || undefined,
    };

    return new Response(JSON.stringify(response), {
      headers: { "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error: any) {
    console.error("Trigger GitHub processing error:", error);

    const response: TriggerGithubProcessingResponse = {
      success: false,
      message: error.message || "Unknown error occurred",
    };

    return new Response(JSON.stringify(response), {
      headers: { "Content-Type": "application/json" },
      status: 500,
    });
  }
});

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  # For single chunk processing (backward compatibility):
  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/trigger-github-processing' \
    --header 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0' \
    --header 'Content-Type: application/json' \
    --data '{"force": true}'

  # For VOD batch processing (new):
  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/trigger-github-processing' \
    --header 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0' \
    --header 'Content-Type: application/json' \
    --data '{"vod_id": 1, "chunks_to_process": 3}'

*/
