import { integer, requireValue } from './http';

/** Compare processing values, allowing equivalent JSON number formatting. */
export function profileCheck(profile: Record<string, any>) {
  const sql: string[] = [];
  const args: unknown[] = [];
  for (const field of ['crop_region', 'igd_crop_region']) {
    const region = profile[field];
    if (region == null) {
      sql.push(`p.${field} IS NULL`);
    } else {
      sql.push(`json_array_length(p.${field})=4`);
      for (let i = 0; i < 4; i++) {
        sql.push(`json_extract(p.${field},'$[${i}]') IS ?`);
        args.push(region[i]);
      }
    }
  }
  sql.push('p.custom_edge IS ?', 'p.opaque_edge IS ?');
  args.push(profile.custom_edge ?? null, profile.opaque_edge ?? false);
  return { sql: sql.join(' AND '), args };
}

export function expectedProfile(value: unknown): Record<string, any> {
  requireValue(value && typeof value === 'object' && !Array.isArray(value), 'Expected processing profile required');
  const profile = value as Record<string, any>;
  integer(profile.id, 'profile ID', 1);
  for (const field of ['crop_region', 'igd_crop_region']) {
    const region = profile[field];
    if (field === 'igd_crop_region' && region == null) continue;
    requireValue(Array.isArray(region) && region.length === 4 && region.every(v => typeof v === 'number' && Number.isFinite(v)), 'Invalid expected crop');
  }
  requireValue(profile.custom_edge == null || (typeof profile.custom_edge === 'number' && Number.isFinite(profile.custom_edge)), 'Invalid expected edge');
  requireValue(typeof profile.opaque_edge === 'boolean', 'Invalid expected opaque edge');
  return profile;
}
