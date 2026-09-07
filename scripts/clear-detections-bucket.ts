import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const url = Deno.env.get("SUPABASE_URL");
const key = Deno.env.get("SUPABASE_SECRET_KEY");
if (!url || !key) {
  throw new Error("SUPABASE_URL and SUPABASE_SECRET_KEY are required");
}
const bucket = createClient(url, key).storage.from("detections");
const pageSize = 1000;

async function listFiles(prefix = ""): Promise<string[]> {
  const files: string[] = [];
  for (let offset = 0;; offset += pageSize) {
    const { data, error } = await bucket.list(prefix, {
      limit: pageSize,
      offset,
      sortBy: { column: "name", order: "asc" },
    });
    if (error) throw error;
    for (const item of data) {
      const path = prefix ? `${prefix}/${item.name}` : item.name;
      if (item.id === null) files.push(...await listFiles(path));
      else files.push(path);
    }
    if (data.length < pageSize) return files;
  }
}

const files = await listFiles();
console.log(`${files.length} files in ${url}/storage/v1/object/detections`);
if (!Deno.args.includes("--execute")) {
  console.log("Dry run. Pass --execute to delete these files.");
} else {
  for (let offset = 0; offset < files.length; offset += 100) {
    const { error } = await bucket.remove(files.slice(offset, offset + 100));
    if (error) throw error; // Do not loop forever on a permanent storage error.
  }
  console.log(`Deleted ${files.length} files.`);
}
