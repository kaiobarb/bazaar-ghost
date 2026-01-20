import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE")!;

const supabase = createClient(supabaseUrl, supabaseServiceKey);

const BUCKET = "detections";
const BATCH_SIZE = 1000;

async function listAllFiles(prefix: string = ""): Promise<string[]> {
  const allFiles: string[] = [];

  const { data, error } = await supabase.storage
    .from(BUCKET)
    .list(prefix, { limit: BATCH_SIZE });

  if (error) {
    console.error(`Error listing ${prefix}:`, error);
    return allFiles;
  }

  if (!data) return allFiles;

  for (const item of data) {
    const path = prefix ? `${prefix}/${item.name}` : item.name;

    if (item.id === null) {
      // It's a folder, recurse into it
      const nestedFiles = await listAllFiles(path);
      allFiles.push(...nestedFiles);
    } else {
      // It's a file
      allFiles.push(path);
    }
  }

  return allFiles;
}

async function clearBucket() {
  console.log(`Clearing bucket: ${BUCKET}`);
  console.log(`Supabase URL: ${supabaseUrl}`);
  console.log("");

  // First, get a count by listing top-level
  const { data: topLevel } = await supabase.storage.from(BUCKET).list("", { limit: 1000 });
  console.log(`Top-level items: ${topLevel?.length || 0}`);

  let totalDeleted = 0;
  let hasMore = true;

  while (hasMore) {
    // List all files recursively (up to batch size worth)
    console.log("\nScanning for files...");
    const files = await listAllFiles("");

    if (files.length === 0) {
      console.log("No more files found");
      hasMore = false;
      break;
    }

    console.log(`Found ${files.length} files to delete`);

    // Delete in batches of 100 (Supabase limit)
    for (let i = 0; i < files.length; i += 100) {
      const batch = files.slice(i, i + 100);

      const { error: deleteError } = await supabase.storage
        .from(BUCKET)
        .remove(batch);

      if (deleteError) {
        console.error("Error deleting batch:", deleteError);
        continue;
      }

      totalDeleted += batch.length;
      console.log(`Deleted ${totalDeleted} files...`);
    }

    // Small delay between iterations
    await new Promise((resolve) => setTimeout(resolve, 500));
  }

  console.log(`\n✓ Done! Total files deleted: ${totalDeleted}`);
}

clearBucket();
