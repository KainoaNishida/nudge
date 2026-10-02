import { APIError,validateAssessment,validateRanking,validateRequest } from './contracts.ts';
import { inputUpperBound,providerBody,ProviderOutputError } from './provider.ts';
import type { AIProvider } from './provider.ts';
import type { Usage } from './dto.ts';
import { promptVersions } from './prompts.ts';
export interface Backend {
  authenticate(token:string):Promise<string>;
  rpc(name:string,params:Record<string,unknown>):Promise<any>;
  deleteAuth(user:string,token:string):Promise<void>;
}
export function createHandler(db:Backend,provider:AIProvider,prompts:{assess:string;rank:string}) {
  return async function handle(req:Request):Promise<Response> {
    const started=Date.now();
    const json=(data:unknown,status=200,headers:Record<string,string>={})=>new Response(JSON.stringify(data),{status,headers:{'content-type':'application/json','cache-control':'no-store',...headers}});
    try {
      const token=req.headers.get('authorization')?.match(/^Bearer (\S+)$/)?.[1];
      if(!token) throw new APIError('authentication_required',401);
      const user=await db.authenticate(token);
      const path=new URL(req.url).pathname;
      const route=path.match(/\/nudge-ai\/v1\/(assess|rank|status|account)$/)?.[1];
      if(!route) throw new APIError('not_found',404);
      if(route==='account' && req.method==='DELETE') {
        await db.rpc('nudge_revoke',{p_user:user});
        await db.deleteAuth(user,token);
        return json({deleted:true});
      }
      const status=await db.rpc('nudge_status',{p_user:user});
      if(route==='status' && req.method==='GET') return json({...status,assessPromptVersion:promptVersions.assess,rankPromptVersion:promptVersions.rank});
      if((route!=='assess' && route!=='rank') || req.method!=='POST') throw new APIError('method_not_allowed',405);
      if(!status.access) throw new APIError('access_denied',403);
      if(!status.rolloutEnabled) throw new APIError('service_paused',503);
      const declared=Number(req.headers.get('content-length'));
      if(declared>262144) throw new APIError('request_too_large',413);
      const reader=req.body?.getReader(); let size=0; const chunks:Uint8Array[]=[];
      if(!reader) throw new APIError('invalid_contract');
      while(true) { const part=await reader.read();if(part.done)break;size+=part.value.length;if(size>262144){await reader.cancel();throw new APIError('request_too_large',413);}chunks.push(part.value); }
      const body=new Uint8Array(size);let offset=0;for(const chunk of chunks){body.set(chunk,offset);offset+=chunk.length;}
      let request:any;try{request=JSON.parse(new TextDecoder().decode(body));}catch{throw new APIError('invalid_contract');}
      validateRequest(route,request);
      const providerRequest=providerBody(status.model,prompts[route],request,route);
      const reservation=await db.rpc('nudge_reserve',{p_user:user,p_request:request.requestId,p_run:request.runId,p_endpoint:route,p_input_bound:inputUpperBound(providerRequest),p_consent:Number(req.headers.get('x-nudge-consent-version'))});
      if(reservation.error) {
        const code=reservation.error;
        throw new APIError(code,code.includes('quota')?402:code==='access_denied'||code==='consent_required'?403:code.includes('limit')?429:409,code.includes('limit')?60:undefined);
      }
      let usage:Usage|undefined; let completed=false;
      try {
        // Reserve and dispatch must use the same server-selected model.
        if(reservation.model!==status.model) throw new APIError('configuration_changed',409);
        const result=await provider.generate(status.model,providerRequest);usage=result.usage;
        if(route==='assess') validateAssessment(request,result.output);else validateRanking(request.recommendations.map((r:any)=>r.id),result.output);
        // Recheck current membership/rollout before returning sensitive inference results.
        const current=await db.rpc('nudge_status',{p_user:user});
        if(!current.access || !current.rolloutEnabled) throw new APIError('access_denied',403);
        await db.rpc('nudge_finish',{p_user:user,p_request:request.requestId,p_state:'completed',p_input:usage.inputTokens,p_output:usage.outputTokens,p_thinking:usage.thinkingTokens});completed=true;
        return json({schemaVersion:1,requestId:request.requestId,runId:request.runId,model:status.model,promptVersion:promptVersions[route],usage,durationMs:Date.now()-started,...result.output as object});
      } catch(error) {
        if(error instanceof ProviderOutputError)usage=error.usage;
        if(!completed) await db.rpc('nudge_finish',{p_user:user,p_request:request.requestId,p_state:usage?'failed':'ambiguous',p_input:usage?.inputTokens??null,p_output:usage?.outputTokens??null,p_thinking:usage?.thinkingTokens??null});
        throw error;
      }
    }catch(error) {
      const safe=error instanceof APIError?error:new APIError('service_unavailable',503);
      return json({error:{code:safe.code,retryAfter:safe.retryAfter??null}},safe.status,safe.retryAfter?{'retry-after':String(safe.retryAfter)}:{});
    }
  };
}
