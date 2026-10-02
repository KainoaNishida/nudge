import { createHandler } from './handler.ts';
import { GeminiProvider } from './provider.ts';
import { APIError } from './contracts.ts';
import { prompts } from './prompts.ts';
const url=Deno.env.get('SUPABASE_URL')!;
const serviceKey=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const headers={'apikey':serviceKey,'authorization':`Bearer ${serviceKey}`,'content-type':'application/json'};
const backend={
  async authenticate(token:string):Promise<string> {
    const response=await fetch(`${url}/auth/v1/user`,{headers:{apikey:serviceKey,authorization:`Bearer ${token}`}});
    if(!response.ok)throw new APIError('authentication_required',401);
    const user=await response.json();if(!user.id || user.is_anonymous)throw new APIError('authentication_required',401);return user.id;
  },
  async rpc(name:string,params:Record<string,unknown>) {
    const response=await fetch(`${url}/rest/v1/rpc/${name}`,{method:'POST',headers,body:JSON.stringify(params)});
    if(!response.ok)throw new APIError('accounting_unavailable',503);
    const text=await response.text();return text?JSON.parse(text):null;
  },
  async deleteAuth(user:string,token:string) {
    // Revoke sessions; membership has already been removed so old JWTs cannot infer.
    const signout=await fetch(`${url}/auth/v1/logout?scope=global`,{method:'POST',headers:{apikey:serviceKey,authorization:`Bearer ${token}`}});
    if(!signout.ok && signout.status!==401)throw new APIError('account_deletion_incomplete',503);
    const response=await fetch(`${url}/auth/v1/admin/users/${user}`,{method:'DELETE',headers});
    if(!response.ok && response.status!==404)throw new APIError('account_deletion_incomplete',503);
  }
};
Deno.serve(createHandler(backend,new GeminiProvider(Deno.env.get('GEMINI_API_KEY')??''),prompts));
