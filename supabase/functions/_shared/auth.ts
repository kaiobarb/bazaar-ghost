/** Internal endpoints accept the configured secret via apikey or Bearer auth. */
export function hasSecretKey(
  req: Request,
  expected: string | undefined,
): boolean {
  if (!expected) return false;
  const bearer = req.headers.get("authorization")?.match(/^Bearer\s+(\S+)$/i)
    ?.[1];
  const supplied = req.headers.get("apikey") || bearer;
  if (!supplied || supplied.length !== expected.length) return false;
  let difference = 0;
  for (let i = 0; i < expected.length; i++) {
    difference |= supplied.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return difference === 0;
}
