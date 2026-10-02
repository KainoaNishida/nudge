import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {validate,validateRequest,validateAssessment,validateRanking,definitions,providerSchema} from '../functions/nudge-ai/contracts.ts';
const read=(file:string)=>JSON.parse(fs.readFileSync(`contracts/fixtures/${file}.json`,'utf8'));
const request=read('assess-request'),response=read('assess-response');
test('all 40 labeled scenarios use the shared contract',()=>{
 const scenarios=read('scenarios');assert.ok(scenarios.length>=40);
 for(const scenario of scenarios){validateRequest('assess',scenario.request);if(scenario.expandedRequest)validateRequest('assess',scenario.expandedRequest);}
 validate('AssessmentResponse',response);validateAssessment(request,{decisions:response.decisions});
});
test('cross-thread, missing, invented and duplicate evidence are rejected',()=>{
 for(const refs of [[{kind:'message',id:'invented'}],[],[{kind:'activity',id:request.threads[0].messages[0].id}],Array(2).fill(response.decisions[0].recommendation.evidenceRefs[0])]) {
  const value=structuredClone(response);value.decisions[0].recommendation.evidenceRefs=refs;assert.throws(()=>validateAssessment(request,valueWithoutEnvelope(value)));
 }
 const cross=structuredClone(request);cross.threads.push({...structuredClone(cross.threads[0]),threadId:'other',snapshotId:'other',messages:[{...cross.threads[0].messages[0],id:'other-message'}]});
 const decisions=structuredClone(response.decisions);decisions[0].recommendation.evidenceRefs[0].id='other-message';decisions.push({...structuredClone(response.decisions[0]),threadId:'other',snapshotId:'other'});assert.throws(()=>validateAssessment(cross,{decisions}));
});
const valueWithoutEnvelope=(v:any)=>({decisions:v.decisions});
test('cardinality, revision, conditional fields, lengths, enums and timestamps are enforced',()=>{
 const changes=[(d:any)=>d.threadId='unknown',(d:any)=>d.snapshotId='old',(d:any)=>d.recommendation.headline='x'.repeat(81),(d:any)=>d.recommendation.confidence='certain',(d:any)=>d.recommendation.reassessAfter='tomorrow',(d:any)=>d.disposition='no_action'];
 for(const change of changes){const out=structuredClone(response);change(out.decisions[0]);assert.throws(()=>validateAssessment(request,valueWithoutEnvelope(out)));}
 assert.throws(()=>validateAssessment(request,{decisions:[]}));assert.throws(()=>validateAssessment(request,{decisions:[...response.decisions,...response.decisions]}));
});
test('rank exact permutation retains all IDs',()=>{
 validateRanking(['a','b','c'],{orderedRecommendationIds:['c','a','b']});
 for(const ids of [['a','b'],['a','b','b'],['a','b','d'],['a','b','c','d']])assert.throws(()=>validateRanking(['a','b','c'],{orderedRecommendationIds:ids}));
});
test('20 initial / 80 expanded, single expanded thread, UTF-8 body and outgoing read limits',()=>{
 const r=structuredClone(request);r.threads[0].messages=Array.from({length:21},(_,n)=>({...request.threads[0].messages[0],id:`m${n}`}));assert.throws(()=>validateRequest('assess',r));
 r.threads[0].contextPass='expanded';validateRequest('assess',r);r.threads[0].messages=Array.from({length:81},(_,n)=>({...request.threads[0].messages[0],id:`m${n}`}));assert.throws(()=>validateRequest('assess',r));
 const utf=structuredClone(request);utf.threads[0].messages[0].body='😀'.repeat(501);assert.throws(()=>validateRequest('assess',utf));
 const outgoing=structuredClone(request);outgoing.threads[0].messages[0].isFromUser=true;assert.throws(()=>validateRequest('assess',outgoing));
});
test('validator supports every keyword in canonical schema and generated provider schema has no references',()=>{
 const allowed=new Set(['type','properties','required','additionalProperties','items','maxItems','minItems','minLength','maxLength','format','minimum','maximum','enum','const','anyOf','$ref']);
 function walk(schema:any){for(const key of Object.keys(schema))assert.ok(allowed.has(key),key);if(schema.properties)Object.values(schema.properties).forEach(walk);if(schema.items)walk(schema.items);if(schema.anyOf)schema.anyOf.forEach(walk);}
 Object.values(definitions).forEach(walk);assert.ok(!JSON.stringify(providerSchema('AssessmentOutput')).includes('$ref'));
});
test('20 labeled priority comparisons conform to ranking contract',()=>{
 const cases=read('ranking-scenarios');assert.equal(cases.length,20);
 for(const scenario of cases)validateRequest('rank',scenario.request);
});
