// Uses ONLY the checked-in synthetic conversations. Never reads the Messages database.
// Run: NUDGE_EVAL_URL=... NUDGE_EVAL_TOKEN=... node scripts/evaluate-ai.mjs results.json
import fs from 'node:fs';
import {randomUUID} from 'node:crypto';
const scenarios=JSON.parse(fs.readFileSync('contracts/fixtures/scenarios.json','utf8'));
const base=process.env.NUDGE_EVAL_URL;
let token=process.env.NUDGE_EVAL_TOKEN,refreshToken=process.env.NUDGE_EVAL_REFRESH_TOKEN;
if(!base||!token)throw Error('Set NUDGE_EVAL_URL to the nudge-ai/v1 route and NUDGE_EVAL_TOKEN to an invited synthetic-test account JWT.');
const batchSize=Number(process.env.NUDGE_EVAL_BATCH_SIZE??1);
if(!Number.isInteger(batchSize)||batchSize<1||batchSize>8)throw Error('Batch size must be between 1 and 8.');
const records=[],rankingComparisons=[];
const save=()=>fs.writeFileSync(process.argv[2]??'.build/ai-evaluation.json',JSON.stringify({records,humanReviewed:false,rankingComparisons,batchSize},null,2));
let lastRequest=0;
async function post(route,body) {
 // Pace every request, including expansions, below twelve requests per minute.
 await new Promise(resolve=>setTimeout(resolve,Math.max(0,lastRequest+5500-Date.now())));
 if(refreshToken&&process.env.NUDGE_EVAL_PUBLIC_KEY){
  const expiry=JSON.parse(Buffer.from(token.split('.')[1],'base64url').toString()).exp;
  if(expiry*1000<Date.now()+90000){
   const response=await fetch(new URL('/auth/v1/token?grant_type=refresh_token',base),{method:'POST',headers:{apikey:process.env.NUDGE_EVAL_PUBLIC_KEY,'content-type':'application/json'},body:JSON.stringify({refresh_token:refreshToken})});
   if(!response.ok)throw Error('Synthetic account session refresh failed.');
   const session=await response.json();token=session.access_token;refreshToken=session.refresh_token;
  }
 }
 lastRequest=Date.now();
 const response=await fetch(`${base}/${route}`,{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json','x-nudge-consent-version':'1'},body:JSON.stringify(body)});
 if(!response.ok)throw Error(`Evaluation ${route} stopped: HTTP ${response.status}; saved results are incomplete.`);
 return response.json();
}
// Only combine scenarios with identical user-level context, as the real app does.
const groups=new Map();
for(const scenario of scenarios){
 const {threads,requestId,runId,...context}=scenario.request;
 const key=JSON.stringify(context);
 if(!groups.has(key))groups.set(key,[]);
 groups.get(key).push(scenario);
}
for(const group of groups.values())for(let start=0;start<group.length;start+=batchSize){
 const batch=group.slice(start,start+batchSize);
 const body=structuredClone(batch[0].request);body.requestId=randomUUID();body.runId=randomUUID();
 body.threads=batch.map(s=>({...structuredClone(s.request.threads[0]),threadId:s.id}));
 const output=await post('assess',body);
 if(output.decisions.length!==batch.length||new Set(output.decisions.map(d=>d.threadId)).size!==batch.length)throw Error('Incomplete synthetic assessment batch.');
 for(const scenario of batch){
  const decision=output.decisions.find(d=>d.threadId===scenario.id);
  if(!decision)throw Error('Missing synthetic assessment decision.');
  const record={id:scenario.id,expected:scenario.expected,decision,model:output.model,promptVersion:output.promptVersion,explanationSupported:null,reviewNotes:''};
  records.push(record);save();
  if(scenario.expandedRequest&&decision.disposition==='needs_context'){
   const expanded=structuredClone(scenario.expandedRequest);expanded.requestId=randomUUID();expanded.runId=body.runId;expanded.threads[0].threadId=scenario.id;
   record.expandedDecision=(await post('assess',expanded)).decisions[0];save();
  }
 }
 console.log(`Assessed ${records.length}/${scenarios.length} synthetic cases.`);
}
for(const scenario of JSON.parse(fs.readFileSync('contracts/fixtures/ranking-scenarios.json','utf8'))){
 const request={...scenario.request,requestId:randomUUID(),runId:randomUUID()};
 const output=await post('rank',request),ids=output.orderedRecommendationIds;
 rankingComparisons.push({id:scenario.id,model:output.model,promptVersion:output.promptVersion,orderedRecommendationIds:ids,urgentOutrankedOptional:Array.isArray(ids)&&ids.length===2&&ids[0]===scenario.urgentId&&ids[1]===scenario.optionalId});save();
}
console.log('Synthetic responses saved. Human evidence review is required before release.');
