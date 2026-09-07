import { atomic } from './atomic';
import { decodeRow, integer, now, one, requireValue, rows, statement, uuid } from './http';
import { source } from './sources';

type Input=Record<string,any>;
function filters(input:Input) {
  const clauses:string[]=[],args:unknown[]=[];
  if(input.search_query!=null) {
    requireValue(typeof input.search_query==='string'&&input.search_query.length<=128,'Invalid search');
    if(input.search_query) {clauses.push("username LIKE ? ESCAPE '\\'");args.push('%'+input.search_query.replace(/[\\%_]/g,(c:string)=>'\\'+c)+'%');}
  }
  if(input.source_filter!=null) {clauses.push('source=?');args.push(source(input.source_filter));}
  if(input.account_filter!=null) {clauses.push('platform_account_id=?');args.push(uuid(input.account_filter));}
  if(input.video_filter!=null) {clauses.push('vod_id=?');args.push(integer(input.video_filter,'video filter',1));}
  return {where:clauses.length?'WHERE '+clauses.join(' AND '):'',args,
    limit:integer(input.result_limit??100,'result_limit',1,500),offset:integer(input.result_offset??0,'result_offset',0,100000)};
}
export async function videoSearch(env:Env,input:Input) {
  const {where,args,limit,offset}=filters(input);
  return (await rows(env,`SELECT * FROM video_detections ${where} ORDER BY indexed_at DESC,detection_id LIMIT ? OFFSET ?`,...args,limit,offset)).map(decodeRow);
}
export async function appearanceSearch(env:Env,input:Input) {
  const {where,args,limit,offset}=filters(input);
  const visible=`WITH visible AS (SELECT coalesce(a.matchup_id,d.detection_id) AS group_id,d.* FROM video_detections d LEFT JOIN matchup_appearances a ON a.detection_id=d.detection_id)`;
  // Select matched groups before pagination, then include all available copies of each matched group.
  const groups=await rows(env,`${visible}, matched AS(SELECT DISTINCT group_id FROM visible ${where})
    SELECT v.group_id,max(v.indexed_at) AS latest,count(*) OVER() AS total_count FROM visible v JOIN matched m USING(group_id)
    GROUP BY v.group_id ORDER BY latest DESC,v.group_id LIMIT ? OFFSET ?`,...args,limit,offset);
  if(!groups.length)return [];
  const copies=await rows(env,`${visible} SELECT * FROM visible WHERE group_id IN(SELECT value FROM json_each(?)) ORDER BY confidence DESC,detection_id`,JSON.stringify(groups.map(g=>g.group_id)));
  return groups.map(group=>{
    const appearances=copies.filter(d=>d.group_id===group.group_id).map(({group_id,...d})=>decodeRow(d));
    return {matchup_id:group.group_id,username:appearances[0].username,appearances,total_count:group.total_count};
  });
}
function evidence(input:Input) {
  requireValue(typeof input.evidence==='string'&&input.evidence.trim().length>=10&&input.evidence.length<=4000,'Provide a substantive verification note');
  return input.evidence.trim();
}
export async function linkAppearances(env:Env,input:Input) {
  const note=evidence(input);
  requireValue(Array.isArray(input.detection_ids)&&input.detection_ids.length<=50,'Provide 2–50 detection IDs');
  const ids=[...new Set<string>(input.detection_ids.map(uuid))].sort();
  requireValue(ids.length>=2,'Provide at least two distinct detections');
  const encoded=JSON.stringify(ids);
  const existing=await rows(env,'SELECT DISTINCT matchup_id FROM matchup_appearances WHERE detection_id IN(SELECT value FROM json_each(?))',encoded);
  requireValue(existing.length<=1,'Conflicting groups require explicit unlinking');
  const id=existing[0]?.matchup_id??crypto.randomUUID();
  await atomic(env,[
    {sql:'SELECT count(*)=? AND count(DISTINCT vod_id)>=2 FROM detections WHERE id IN(SELECT value FROM json_each(?))',args:[ids.length,encoded]},
    {sql:'SELECT NOT EXISTS(SELECT 1 FROM matchup_appearances WHERE detection_id IN(SELECT value FROM json_each(?)) AND matchup_id<>?)',args:[encoded,id]},
    {sql:'SELECT count(*)<=50 FROM (SELECT detection_id FROM matchup_appearances WHERE matchup_id=? UNION SELECT value FROM json_each(?))',args:[id,encoded]},
  ],[
    statement(env,'INSERT OR IGNORE INTO matchup_groups(id,evidence) VALUES(?,?)',id,note),
    statement(env,'INSERT OR IGNORE INTO matchup_appearances(detection_id,matchup_id) SELECT value,? FROM json_each(?)',id,encoded),
    statement(env,"INSERT INTO matchup_review_events(id,matchup_id,action,detection_ids,evidence) VALUES(?,?,'link',?,?)",crypto.randomUUID(),id,encoded,note),
  ]);
  return {matchup_id:id};
}
export async function unlinkAppearance(env:Env,input:Input) {
  const id=uuid(input.detection_id),note=evidence(input);
  const existing=await one(env,'SELECT matchup_id FROM matchup_appearances WHERE detection_id=?',id);
  if(!existing)return {unlinked:false};
  await atomic(env,[{sql:'SELECT EXISTS(SELECT 1 FROM matchup_appearances WHERE detection_id=? AND matchup_id=?)',args:[id,existing.matchup_id]}],[
    statement(env,"INSERT INTO matchup_review_events(id,matchup_id,action,detection_ids,evidence,created_at) VALUES(?,?,'unlink',?,?,?)",crypto.randomUUID(),existing.matchup_id,JSON.stringify([id]),note,now()),
    statement(env,'DELETE FROM matchup_appearances WHERE detection_id=?',id),
  ]);
  return {unlinked:true};
}
