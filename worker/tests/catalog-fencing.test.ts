import { env } from "cloudflare:workers";
import { beforeEach, afterEach, expect, it, vi } from "vitest";
import { catalogRoute, enqueueJob, saveVideo, updateAccount, upsertAccount } from "../platforms";
import { now, one, rows, statement } from "../http";

const A="10000000-0000-4000-8000-000000000001", B="10000000-0000-4000-8000-000000000002", C="10000000-0000-4000-8000-000000000003";
const channel="UC"+"a".repeat(22), otherChannel="UC"+"b".repeat(22), videoId="abcdefghijk", bv="BV1234567890";
const hosted=()=>({...env,ENVIRONMENT:"validation",OUTBOUND_ENABLED:"true",PUBLIC_URL:"https://validation.example.org"});
type Job={id:string;lease_token:string};
const fence=(job:Job)=>({job_id:job.id,lease_token:job.lease_token});
async function job(source="youtube",kind="video",sourceId=videoId,account:string|null=A):Promise<Job> {
  const id=crypto.randomUUID(),lease_token=crypto.randomUUID();
  await statement(env, `INSERT INTO platform_ingestion_jobs(id,source,kind,source_id,account_id,status,lease_token,lease_expires_at)
    VALUES(?,?,?,?,?,'processing',?,?)`,id,source,kind,sourceId,account,lease_token,new Date(Date.now()+600_000).toISOString()).run();
  return {id,lease_token};
}
function video(id=videoId) {return {source:"youtube",source_id:id,title:"The Bazaar footage",duration_seconds:60,bazaar_chapters:[0,60]};}
function part(id=bv,cid="123") {return {...video(),source:"bilibili",source_id:`${id}:${cid}`,source_video_id:id,source_part_id:cid,source_part_index:1};}
function call(path:string, input:Record<string,unknown>, runtime=env) {
  return catalogRoute(new Request(`https://validation.example.org/api/catalog/${path}`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(input)}),runtime);
}
beforeEach(async()=>{
  vi.stubGlobal("fetch",vi.fn(()=>{throw new Error("Network prohibited");}));
  await statement(env,"INSERT INTO sfde_profiles(id,profile_name,crop_region) VALUES(1,'fences','[0,0,1,1]')").run();
  for(const [id,source,sourceId] of [[A,"youtube",channel],[B,"youtube",otherChannel],[C,"bilibili","12345"]])
    await statement(env,"INSERT INTO platform_accounts(id,source,source_id,display_name,processing_enabled) VALUES(?,?,?,'Original',1)",id,source,sourceId).run();
});
afterEach(()=>{vi.restoreAllMocks();vi.unstubAllGlobals();});

it("preserves automatic discovery -> verified account -> attachment -> video ingestion",async()=>{
  const discovery=await job("youtube","discovery","bazaar",null);
  await enqueueJob(env,{source:"youtube",kind:"video",source_id:videoId,...fence(discovery)});
  const candidate=(await one(env,"SELECT * FROM platform_ingestion_jobs WHERE kind='video'"))!;
  const token=crypto.randomUUID();
  await statement(env,"UPDATE platform_ingestion_jobs SET status='processing',lease_token=?,lease_expires_at=? WHERE id=?",token,new Date(Date.now()+600_000).toISOString(),candidate.id).run();
  const proof={id:candidate.id,lease_token:token};
  const account=await upsertAccount(env,{source:"youtube",source_id:channel,display_name:"Verified creator",processing_enabled:true,...fence(proof)});
  expect(account.id).toBe(A);
  expect(await (await call("jobs/attach-account",{id:proof.id,token:proof.lease_token,account_id:A})).json()).toBe(true);
  const saved=await saveVideo(env,{account_id:A,video:video(),...fence(proof)});
  expect(saved.source_id).toBe(videoId);
  expect((await rows(env,"SELECT * FROM chunks WHERE vod_id=?",saved.id)).length).toBe(1);
});
it("rejects a live lease for another source, video, owner, job kind, or token before metadata writes",async()=>{
  const cases=[
    await job("youtube","account",channel,A),
    await job("bilibili","video",bv,C),
    await job("youtube","video","12345678901",A),
    await job("youtube","video",videoId,B),
  ];
  for(const lease of cases)
    await expect(saveVideo(env,{account_id:A,video:video(),...fence(lease)})).rejects.toMatchObject({status:409});
  await expect(saveVideo(env,{account_id:A,video:video(),job_id:cases[0].id,lease_token:cases[1].lease_token})).rejects.toMatchObject({status:409});
  expect(await rows(env,"SELECT * FROM vods")).toEqual([]);
});
it("requires automatic video-account attachment, but preserves manual catalog calls",async()=>{
  const lease=await job("youtube","video",videoId,null);
  await expect(saveVideo(env,{account_id:A,video:video(),...fence(lease)})).rejects.toMatchObject({status:409});
  expect((await saveVideo(env,{account_id:A,video:video()})).source_id).toBe(videoId);
});
it("fences all Bilibili parts to the leased submission",async()=>{
  const lease=await job("bilibili","video",bv,C);
  for(const cid of ["123","456"])
    expect((await saveVideo(env,{account_id:C,video:part(bv,cid),...fence(lease)})).source_id).toBe(`${bv}:${cid}`);
  await expect(saveVideo(env,{account_id:C,video:part("BVabcdefghij"),...fence(lease)})).rejects.toMatchObject({status:409});
  expect((await rows(env,"SELECT * FROM vods")).length).toBe(2);
});
it("binds account upserts to the verified candidate source and an already bound owner",async()=>{
  const lease=await job();
  await expect(upsertAccount(env,{source:"youtube",source_id:otherChannel,display_name:"Forged",...fence(lease)})).rejects.toMatchObject({status:409});
  await expect(upsertAccount(env,{source:"bilibili",source_id:"12345",display_name:"Forged",...fence(lease)})).rejects.toMatchObject({status:409});
  const accountLease=await job("youtube","account",channel,A);
  await expect(upsertAccount(env,{source:"youtube",source_id:channel,display_name:"Forged",...fence(accountLease)})).rejects.toMatchObject({status:409});
  expect((await one(env,"SELECT display_name FROM platform_accounts WHERE id=?",A))!.display_name).toBe("Original");
});
it("automatic discovery preserves operator disables without relying on a client preserve flag",async()=>{
  const lease=await job();
  await statement(env,"UPDATE platform_accounts SET processing_enabled=0 WHERE id=?",A).run();
  const account=await upsertAccount(env,{source:"youtube",source_id:channel,display_name:"New name",processing_enabled:true,preserve_disabled:false,...fence(lease)});
  expect(account.processing_enabled).toBe(false);
  await expect(upsertAccount(env,{source:"youtube",source_id:channel,display_name:"Bad settings",sfde_profile_id:1,...fence(lease)})).rejects.toMatchObject({status:400});
});
it("allows account cursor updates only from that account's enabled catalog job",async()=>{
  const lease=await job("youtube","account",channel,A),videoLease=await job();
  expect((await updateAccount(env,A,{catalog_cursor:2,...fence(lease)})).catalog_cursor).toBe(2);
  await expect(updateAccount(env,B,{catalog_cursor:3,...fence(lease)})).rejects.toMatchObject({status:409});
  await expect(updateAccount(env,A,{catalog_cursor:3,...fence(videoLease)})).rejects.toMatchObject({status:409});
  await expect(updateAccount(env,A,{processing_enabled:false,...fence(lease)})).rejects.toMatchObject({status:400});
  await statement(env,"UPDATE platform_accounts SET processing_enabled=0 WHERE id=?",A).run();
  await expect(updateAccount(env,A,{catalog_cursor:3,...fence(lease)})).rejects.toMatchObject({status:409});
});
it("constrains automatic enqueues by discovery/account/video responsibility",async()=>{
  const discovery=await job("youtube","discovery","bazaar",null);
  await enqueueJob(env,{source:"youtube",kind:"video",source_id:videoId,...fence(discovery)});
  await expect(enqueueJob(env,{source:"bilibili",kind:"video",source_id:bv,...fence(discovery)})).rejects.toMatchObject({status:409});
  await expect(enqueueJob(env,{source:"youtube",kind:"video",source_id:"12345678901",account_id:A,...fence(discovery)})).rejects.toMatchObject({status:409});
  const accountLease=await job("youtube","account",channel,A);
  await enqueueJob(env,{source:"youtube",kind:"video",source_id:"12345678901",account_id:A,...fence(accountLease)});
  await expect(enqueueJob(env,{source:"youtube",kind:"video",source_id:"12345678902",account_id:B,...fence(accountLease)})).rejects.toMatchObject({status:409});
  const candidate=(await one(env,"SELECT * FROM platform_ingestion_jobs WHERE source_id=?",videoId))!;
  const token=crypto.randomUUID();
  await statement(env,"UPDATE platform_ingestion_jobs SET account_id=?,status='processing',lease_token=?,lease_expires_at=? WHERE id=?",A,token,new Date(Date.now()+600_000).toISOString(),candidate.id).run();
  const videoLease={id:candidate.id,lease_token:token};
  await enqueueJob(env,{source:"youtube",kind:"account",source_id:channel,account_id:A,...fence(videoLease)});
  await expect(enqueueJob(env,{source:"youtube",kind:"account",source_id:otherChannel,account_id:B,...fence(videoLease)})).rejects.toMatchObject({status:409});
  await expect(enqueueJob(env,{source:"youtube",kind:"video",source_id:"12345678903",account_id:A,...fence(videoLease)})).rejects.toMatchObject({status:409});
});
it("rejects attachment across platform, from non-video jobs, or away from an existing owner",async()=>{
  const lease=await job("youtube","video",videoId,null);
  await expect(call("jobs/attach-account",{id:lease.id,token:lease.lease_token,account_id:C})).rejects.toMatchObject({status:409});
  await call("jobs/attach-account",{id:lease.id,token:lease.lease_token,account_id:A});
  await expect(call("jobs/attach-account",{id:lease.id,token:lease.lease_token,account_id:B})).rejects.toMatchObject({status:409});
  const accountLease=await job("youtube","account",channel,A);
  await expect(call("jobs/attach-account",{id:accountLease.id,token:accountLease.lease_token,account_id:A})).rejects.toMatchObject({status:409});
  expect((await one(env,"SELECT account_id FROM platform_ingestion_jobs WHERE id=?",lease.id))!.account_id).toBe(A);
});
it("blocks automatic metadata and enqueues after account disablement",async()=>{
  const videoLease=await job(),accountLease=await job("youtube","account",channel,A);
  await statement(env,"UPDATE platform_accounts SET processing_enabled=0 WHERE id=?",A).run();
  await expect(saveVideo(env,{account_id:A,video:video(),...fence(videoLease)})).rejects.toMatchObject({status:409});
  await expect(enqueueJob(env,{source:"youtube",kind:"video",source_id:"12345678901",account_id:A,...fence(accountLease)})).rejects.toMatchObject({status:409});
  expect(await rows(env,"SELECT * FROM vods")).toEqual([]);
});
it("fences renewal by target account and live account-job lease before any subscription write",async()=>{
  const accountLease=await job("youtube","account",channel,A),videoLease=await job();
  await expect(call("subscriptions/renew",{account_id:B,...fence(accountLease)},hosted())).rejects.toMatchObject({status:409});
  await expect(call("subscriptions/renew",{account_id:A,...fence(videoLease)},hosted())).rejects.toMatchObject({status:409});
  await statement(env,"UPDATE platform_ingestion_jobs SET lease_expires_at=? WHERE id=?",new Date(Date.now()-1).toISOString(),accountLease.id).run();
  await expect(call("subscriptions/renew",{account_id:A,...fence(accountLease)},hosted())).rejects.toMatchObject({status:409});
  expect(await rows(env,"SELECT * FROM youtube_websub_subscriptions")).toEqual([]);
  expect(fetch).not.toHaveBeenCalled();
});
it("does not write a failed renewal result after losing its ingestion lease",async()=>{
  const lease=await job("youtube","account",channel,A);
  vi.stubGlobal("fetch",vi.fn(async()=>{
    await statement(env,"UPDATE platform_ingestion_jobs SET lease_expires_at=? WHERE id=?",now(),lease.id).run();
    throw new Error("ambiguous upstream error");
  }));
  await expect(call("subscriptions/renew",{account_id:A,...fence(lease)},hosted())).rejects.toMatchObject({status:409});
  const subscription=(await one(env,"SELECT * FROM youtube_websub_subscriptions"))!;
  expect(subscription.requested_at).not.toBeNull(); expect(subscription.last_error).toBeNull();
});
