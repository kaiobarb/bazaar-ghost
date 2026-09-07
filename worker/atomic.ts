import { HttpError, statement } from "./http";

/** A D1 batch is one transaction. CHECK assertions fence reads against racing writes. */
export async function atomic(
  env: Env,
  checks: Array<{ sql: string; args: unknown[] }>,
  mutations: D1PreparedStatement[],
) {
  if (!checks.length) return env.DB.batch(mutations);
  const id = crypto.randomUUID();
  try {
    return await env.DB.batch([
      ...checks.map((check, i) => statement(env,
        `INSERT INTO mutation_checks(id,ok) VALUES(?,(${check.sql}))`,
        `${id}:${i}`, ...check.args)),
      ...mutations,
      statement(env, "DELETE FROM mutation_checks WHERE id LIKE ?", `${id}:%`),
    ]);
  } catch (error) {
    if (String(error).includes("valid_mutation"))
      throw new HttpError(409, "State changed or lease expired; refresh before retrying");
    throw error;
  }
}
