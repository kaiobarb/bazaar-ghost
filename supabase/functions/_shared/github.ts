/** GitHub Actions integration for triggering VOD processing workflows. */

const GITHUB_OWNER = "kaiobarb";
const GITHUB_REPO = "bazaar-ghost";
const GITHUB_TOKEN = Deno.env.get("GITHUB_TOKEN")!;

/** VODs published on or before this date use the legacy (smaller) templates. */
export const OLD_TEMPLATES_CUTOFF = new Date("2025-08-12T00:00:00Z");

/**
 * Dispatch the process-vod GitHub Actions workflow for a set of chunks.
 * Returns the Actions page URL on success, throws on API error.
 */
export async function triggerGithubWorkflow(
  vodId: string,
  chunkUuids: string[],
  oldTemplates: boolean,
  sfdeProfile: string,
  environment: string,
): Promise<string> {
  const url =
    `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/workflows/process-vod.yml/dispatches`;

  const branch = environment === "dev" ? "dev" : "main";

  console.log(
    `Triggering workflow for VOD ${vodId} with ${chunkUuids.length} chunks (old_templates: ${oldTemplates}, environment: ${environment})`,
  );

  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${GITHUB_TOKEN}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      ref: branch,
      inputs: {
        vod_id: vodId,
        chunk_uuids: JSON.stringify(chunkUuids),
        old_templates: oldTemplates.toString(),
        sfde_profile: sfdeProfile,
        environment,
      },
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(
      `GitHub API error: ${response.status} ${response.statusText} - ${errorText}`,
    );
  }

  return `https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/actions/workflows/process-vod.yml`;
}
