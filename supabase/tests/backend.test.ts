import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {createHandler} from '../functions/nudge-ai/handler.ts';
import {GeminiProvider,providerBody,ProviderOutputError} from '../functions/nudge-ai/provider.ts';
import {APIError,providerSchema,validateAssessment} from '../functions/nudge-ai/contracts.ts';
import {promptVersions} from '../functions/nudge-ai/prompts.ts';
const payload=JSON.parse(fs.readFileSync('contracts/fixtures/assess-request.json','utf8'));
const output=JSON.parse(fs.readFileSync('contracts/fixtures/assess-response.json','utf8'));
function setup(overrides:any={}) {
 const calls:any[]=[];
 const db={authenticate:async()=> 'user-a',rpc:async(name:string,params:any)=>{calls.push({name,params});if(name==='nudge_status')return {access:true,rolloutEnabled:true,model:'gemini-3.8-flash'};if(name==='nudge_reserve')return {model:'gemini-3.8-flash'};return null;},deleteAuth:async()=>{},...overrides};
 const provider={generate:async()=>({output:{decisions:output.decisions},usage:output.usage})};
 return {db,provider,calls,handler:createHandler(db,provider,{assess:'assess',rank:'rank'})};
}
const request=()=>new Request('https://test/functions/v1/nudge-ai/v1/assess',{method:'POST',headers:{authorization:'Bearer valid','x-nudge-consent-version':'1'},body:JSON.stringify(payload)});
test('unauthenticated and non-member requests never call provider',async()=>{
 const {handler,calls}=setup();assert.equal((await handler(new Request(request().url,{method:'POST'}))).status,401);assert.equal(calls.length,0);
 const s=setup({rpc:async()=>({access:false})});assert.equal((await s.handler(request())).status,403);
});
test('reserve precedes generation and successful response reconciles usage',async()=>{
 const s=setup();s.provider.generate=async()=>{assert.equal(s.calls.at(-1).name,'nudge_reserve');return {output:{decisions:output.decisions},usage:output.usage};};
 const response=await s.handler(request());assert.equal(response.status,200);assert.equal(s.calls.at(-1).params.p_thinking,20);
 assert.ok(s.calls.every(c=>!JSON.stringify(c).includes(payload.threads[0].messages[0].body)));
});
test('status and responses advertise the versions of the deployed prompt files',async()=>{
 const s=setup();
 const status=await (await s.handler(new Request('https://test/functions/v1/nudge-ai/v1/status',{headers:{authorization:'Bearer valid'}}))).json();
 const response=await (await s.handler(request())).json();
 assert.equal(status.assessPromptVersion,promptVersions.assess);
 assert.equal(status.rankPromptVersion,promptVersions.rank);
 assert.equal(response.promptVersion,status.assessPromptVersion);
});
test('timeout retains ambiguous charge and reports retry timing',async()=>{
 const s=setup();s.provider.generate=async()=>{throw new APIError('provider_timeout',504,5);};const response=await s.handler(request());assert.equal(response.status,504);assert.equal(s.calls.at(-1).params.p_state,'ambiguous');assert.equal(s.calls.at(-1).params.p_input,null);assert.equal(response.headers.get('retry-after'),'5');
});
test('invalid or partial output fails without changing content or returning invented decisions',async()=>{
 const s=setup();s.provider.generate=async()=>({output:{decisions:[]},usage:output.usage});const response=await s.handler(request());assert.equal(response.status,502);assert.equal(s.calls.at(-1).params.p_state,'failed');assert.equal(s.calls.at(-1).params.p_input,100);
});
test('provider is stateless, has no tools, counts thinking, and rejects incomplete results',async()=>{
 const body=providerBody('gemini-3.8-flash','prompt',payload,'assess');assert.equal(body.store,false);assert.equal(body.generation_config.thinking_level,'low');assert.ok(!('tools' in body));assert.ok(!('previous_interaction_id' in body));
 const p=new GeminiProvider('synthetic',async()=>new Response(JSON.stringify({status:'completed',steps:[{type:'model_output',content:[{type:'text',text:JSON.stringify({decisions:output.decisions})}]}],usage:{total_input_tokens:100,total_output_tokens:50,total_thought_tokens:20}})));
 assert.deepEqual((await p.generate('model',body)).usage,output.usage);
 const incomplete=new GeminiProvider('synthetic',async()=>new Response(JSON.stringify({status:'failed',usage:{total_input_tokens:100,total_output_tokens:50,total_thought_tokens:20}})));await assert.rejects(()=>incomplete.generate('model',body),ProviderOutputError);
});
test('provider schema stays within Gemini grammar limits while server retains strict bounds',()=>{
 const schema=providerSchema('AssessmentOutput');
 const serialized=JSON.stringify(schema);
 assert.doesNotMatch(serialized,/"(?:\$ref|const|minLength|maxLength|minItems|maxItems)":/);
 const decision=schema.properties.decisions.items;
 assert.deepEqual(decision.properties.recommendation.type,['object','null']);
 assert.deepEqual(decision.properties.contextRequest.properties.totalMessages.enum,[80]);
 assert.match(schema.properties.decisions.description,/Maximum items: 8/);
 const long=structuredClone({decisions:output.decisions});long.decisions[0].recommendation.headline='x'.repeat(81);
 assert.throws(()=>validateAssessment(payload,long),APIError);
 const many=structuredClone({decisions:output.decisions});many.decisions=Array.from({length:9},()=>many.decisions[0]);
 assert.throws(()=>validateAssessment(payload,many),APIError);
});
test('no application backend source logs private payloads',()=>{
 for(const file of ['index.ts','handler.ts','provider.ts','contracts.ts'])assert.doesNotMatch(fs.readFileSync(`supabase/functions/nudge-ai/${file}`,'utf8'),/console\.(log|error|warn|info)|JSON\.stringify\(error\)/);
});
