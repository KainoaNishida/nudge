import { APIError, providerSchema } from './contracts.ts';
import type { Usage } from './dto.ts';
export type ProviderResult = { output: unknown; usage: Usage };
export interface AIProvider { generate(model: string, body: object): Promise<ProviderResult> }
export function providerBody(model: string, prompt: string, payload: unknown, kind: 'assess'|'rank') {
  return { model, input: JSON.stringify(payload), system_instruction: prompt, store: false,
    // https://ai.google.dev/gemini-api/docs/thinking: this cap includes thinking.
    generation_config: { thinking_level: 'low', max_output_tokens: 8192 },
    response_format: { type: 'text', mime_type: 'application/json', schema: providerSchema(kind === 'assess' ? 'AssessmentOutput':'RankingOutput') } };
}
export function inputUpperBound(body: object): number {
  // UTF-8 byte count is a conservative text token upper bound, plus framing allowance.
  const size = new TextEncoder().encode(JSON.stringify(body)).length + 4096;
  if(size>300000) throw new APIError('request_too_large',413);
  return size;
}
export class GeminiProvider implements AIProvider {
  key: string; transport: typeof fetch;
  constructor(key: string, transport: typeof fetch = fetch) { this.key=key; this.transport=transport; }
  async generate(_model: string, body: object): Promise<ProviderResult> {
    let response: Response;
    try {
      response = await this.transport('https://generativelanguage.googleapis.com/v1beta/interactions',{
        method:'POST', headers:{'content-type':'application/json','x-goog-api-key':this.key},body:JSON.stringify(body),signal:AbortSignal.timeout(90000)
      });
    } catch { throw new APIError('provider_timeout',504,5); }
    if(!response.ok) {
      const delay=Number(response.headers.get('retry-after'));
      if(response.status===429 || response.status>=500) throw new APIError('provider_transient',503, Number.isFinite(delay) && delay>0 ? Math.min(delay,300):5);
      throw new APIError('provider_rejected',502);
    }
    // Never log upstream payloads, error bodies, goals, or generated text.
    let data: any; try { data=await response.json(); } catch { throw new APIError('provider_invalid_output',502); }
    const u=data.usage;
    if(!u || ![u.total_input_tokens,u.total_output_tokens,u.total_thought_tokens].every(x=>Number.isSafeInteger(x)&&x>=0)) throw new APIError('provider_usage_missing',502);
    const usage={inputTokens:u.total_input_tokens,outputTokens:u.total_output_tokens,thinkingTokens:u.total_thought_tokens};
    if(data.status!=='completed') throw new ProviderOutputError('provider_incomplete',usage);
    const texts=(data.steps??[]).filter((s:any)=>s.type==='model_output').flatMap((s:any)=>s.content??[]).filter((c:any)=>c.type==='text').map((c:any)=>c.text);
    const text=typeof data.output_text==='string' ? data.output_text : texts.join('');
    try { return {output:JSON.parse(text),usage}; } catch { throw new ProviderOutputError('provider_invalid_output',usage); }
  }
}
export class ProviderOutputError extends APIError { usage: Usage; constructor(code:string,usage:Usage) {super(code,502);this.usage=usage;} }
