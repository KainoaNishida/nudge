import test from 'node:test';
import assert from 'node:assert/strict';
import {PGlite} from '@electric-sql/pglite';
import fs from 'node:fs';
import {randomUUID} from 'node:crypto';
const migration=fs.readFileSync('supabase/migrations/20261001191955_managed_ai.sql','utf8');
async function database(){
 const db=new PGlite();await db.exec('create schema auth; create table auth.users(id uuid primary key); create role anon; create role authenticated; create role service_role bypassrls;');await db.exec(migration);
 await db.exec("update public.nudge_config set rollout_enabled=true; update public.nudge_pricing set effective_at=now()-interval '1 day',expires_at=now()+interval '1 day';");return db;
}
const u='11111111-1111-4111-8111-111111111111';
async function member(db:PGlite){await db.query('insert into auth.users values($1)',[u]);await db.query('insert into nudge_memberships(user_id) values($1)',[u]);}
async function reserve(db:PGlite,id=randomUUID(),input=1000,user=u){const r=await db.query<{result:any}>('select nudge_reserve($1,$2,$3,$4,$5,$6) as result',[user,id,randomUUID(),'assess',input,1]);return r.rows[0].result;}
test('atomic limits, duplicate IDs, timeout charges, reconciliation, rate and cap enforcement',async()=>{
 const db=await database();try{await member(db);
 const id=randomUUID();const first=await reserve(db,id);assert.ok(first.reservedMicrousd>0);
 assert.equal((await reserve(db,id)).error,'request_in_progress');
 const second=randomUUID();await reserve(db,second);assert.equal((await reserve(db)).error,'concurrency_limit');
 await db.query('select nudge_finish($1,$2,$3,$4,$5,$6)',[u,id,'completed',100,50,20]);
 assert.equal((await reserve(db,id)).error,'response_not_replayable');
 let totals=await db.query<{charged_microusd:number}>('select charged_microusd from nudge_monthly_users');assert.equal(Number(totals.rows[0].charged_microusd),first.reservedMicrousd+Math.ceil(100*.75+70*3.75));
 await db.query('select nudge_finish($1,$2,$3)',[u,second,'ambiguous']);
 totals=await db.query('select charged_microusd from nudge_monthly_users');assert.equal(Number(totals.rows[0].charged_microusd),first.reservedMicrousd+338);
 await db.exec('update nudge_monthly_users set charged_microusd=4999999');assert.equal((await reserve(db)).error,'quota_exhausted');
 await db.exec('update nudge_monthly_users set charged_microusd=0;update nudge_config set global_cap_microusd=1');assert.equal((await reserve(db)).error,'global_quota_exhausted');
 }finally{await db.close();}
});
test('unauthorized accounts, stale consent, paused rollout, expired pricing and client writes fail closed',async()=>{
 const db=await database();try{assert.equal((await reserve(db)).error,'access_denied');await member(db);
 await db.exec('update nudge_config set consent_version=2');assert.equal((await reserve(db)).error,'consent_required');
 await db.exec('update nudge_config set consent_version=1,kill_switch=true');assert.equal((await reserve(db)).error,'service_paused');
 await db.exec("update nudge_config set kill_switch=false;update nudge_pricing set effective_at=now()-interval '2 days',expires_at=now()-interval '1 day'");assert.equal((await reserve(db)).error,'pricing_unavailable');
 await db.exec('set role authenticated');await assert.rejects(()=>db.exec('update nudge_config set global_cap_microusd=999999999'));await assert.rejects(()=>reserve(db));await db.exec('reset role');
 }finally{await db.close();}
});
test('month reconciliation targets reservation month and account deletion retains anonymous global charge',async()=>{
 const db=await database();try{await member(db);const id=randomUUID();await reserve(db,id);
 await db.exec("update nudge_requests set month=date_trunc('month',now() at time zone 'UTC')::date-interval '1 month';update nudge_monthly_global set month=month-interval '1 month';update nudge_monthly_users set month=month-interval '1 month'");
 await db.query('select nudge_finish($1,$2,$3,$4,$5,$6)',[u,id,'completed',100,50,20]);
 const previous=await db.query<{charged_microusd:number}>('select charged_microusd from nudge_monthly_users');assert.equal(Number(previous.rows[0].charged_microusd),338);
 const next=await reserve(db);assert.ok(next.reservedMicrousd>0);assert.equal((await db.query('select * from nudge_monthly_users')).rows.length,2);
 await db.query('select nudge_revoke($1)',[u]);assert.equal((await reserve(db)).error,'access_denied');assert.equal((await db.query('select * from nudge_requests')).rows.length,0);assert.equal((await db.query('select * from nudge_monthly_global')).rows.length,2);
 }finally{await db.close();}
});
test('parallel reservations never exceed two in flight; fresh retries count and rate limit is server enforced',async()=>{
 const db=await database();try{await member(db);
 const results=await Promise.all(Array.from({length:8},()=>reserve(db)));
 assert.equal(results.filter(r=>!r.error).length,2);assert.equal(results.filter(r=>r.error==='concurrency_limit').length,6);
 const active=await db.query<{request_id:string}>('select request_id from nudge_requests');
 for(const row of active.rows)await db.query('select nudge_finish($1,$2,$3)',[u,row.request_id,'ambiguous']);
 for(let n=0;n<10;n++){const id=randomUUID();assert.ok(!(await reserve(db,id)).error);await db.query('select nudge_finish($1,$2,$3,$4,$5,$6)',[u,id,'completed',1,1,1]);}
 assert.equal((await reserve(db)).error,'rate_limit');
 const count=await db.query<{count:number}>('select count(*) as count from nudge_requests');assert.equal(Number(count.rows[0].count),12);
 }finally{await db.close();}
});
