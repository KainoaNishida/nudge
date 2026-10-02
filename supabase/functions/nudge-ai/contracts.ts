import schema from './contracts/v1.json' with { type: 'json' };
// The JSON Schema is the contract source of truth. This small validator implements exactly
// the vocabulary used there; unsupported keywords fail closed in the contract test.
export class APIError extends Error {
  code: string; status: number; retryAfter?: number;
  constructor(code: string, status = 400, retryAfter?: number) { super(code); this.code=code; this.status=status; this.retryAfter=retryAfter; }
}
type Schema = { [key: string]: any };
export const definitions = schema.$defs as Record<string, Schema>;
export function validate(name: string, value: unknown): void {
  function check(s: Schema, v: any): boolean {
    if (s.$ref) return check(definitions[s.$ref.split('/').pop()!], v);
    if (s.anyOf) return s.anyOf.some((x: Schema) => check(x,v));
    if (s.const !== undefined && s.const !== v) return false;
    if (s.enum && !s.enum.includes(v)) return false;
    switch(s.type) {
      case 'null': return v === null;
      case 'boolean': return typeof v === 'boolean';
      case 'integer': case 'number': return typeof v === 'number' && Number.isFinite(v) && (s.type !== 'integer' || Number.isInteger(v)) && v >= (s.minimum ?? -Infinity) && v <= (s.maximum ?? Infinity);
      case 'string': return typeof v === 'string' && [...v].length >= (s.minLength ?? 0) && [...v].length <= (s.maxLength ?? Infinity) &&
        (!s.format || (s.format === 'uuid' ? /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v) : /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/.test(v) && !Number.isNaN(Date.parse(v)) && new Date(v).toISOString().slice(0,19) === v.slice(0,19)));
      case 'array': return Array.isArray(v) && v.length >= s.minItems && v.length <= s.maxItems && v.every((x: any) => check(s.items,x));
      case 'object': return v !== null && typeof v === 'object' && !Array.isArray(v) && s.required.every((key: string) => key in v) && Object.keys(v).every(key => key in s.properties) && Object.entries(s.properties).every(([key,child]) => check(child as Schema,v[key]));
      default: return false;
    }
  }
  if (!definitions[name] || !check(definitions[name], value)) throw new APIError('invalid_contract');
}
export function providerSchema(name: string): Schema {
  // Keep the public contract strict, but project it into Gemini's generation subset.
  // Nested bounded arrays can exceed its grammar-complexity limit. Describe those
  // bounds to the model and enforce them with validate() after generation.
  const expand = (s: Schema): Schema => {
    if (s.$ref) return expand(definitions[s.$ref.split('/').pop()!]);
    if (s.anyOf?.length === 2 && s.anyOf[1].type === 'null') {
      const value = expand(s.anyOf[0]);
      return {...value, type: [value.type, 'null']};
    }
    const result: Schema = {};
    for (const [key,value] of Object.entries(s)) {
      if (['minLength','maxLength','minItems','maxItems','const'].includes(key)) continue;
      if (key === 'properties') result[key] = Object.fromEntries(Object.entries(value).map(([field,child]) => [field,expand(child as Schema)]));
      else if (key === 'items') result[key] = expand(value);
      else if (key === 'anyOf') result[key] = value.map(expand);
      else result[key] = value;
    }
    if (s.const !== undefined) result.enum = [s.const];
    const bounds = [['minLength','Minimum characters'],['maxLength','Maximum characters'],['minItems','Minimum items'],['maxItems','Maximum items']]
      .filter(([key]) => s[key] !== undefined).map(([key,label]) => `${label}: ${s[key]}.`);
    if (bounds.length) result.description = [result.description,...bounds].filter(Boolean).join(' ');
    return result;
  }; return expand(definitions[name]);
}
export function validateAssessment(request: any, output: any): void {
  try { validate('AssessmentOutput',output); } catch { throw new APIError('provider_invalid_output',502); }
  const seen = new Set<string>();
  if(output.decisions.length !== request.threads.length) throw new APIError('incomplete_decisions',502);
  for(const d of output.decisions) {
    const t = request.threads.find((t:any) => t.threadId === d.threadId);
    if (!t || seen.has(d.threadId) || t.snapshotId !== d.snapshotId) throw new APIError('invalid_thread',502);
    seen.add(d.threadId);
    if (d.disposition === 'recommend') {
      const r = d.recommendation;
      if (!r || d.contextRequest !== null || (r.basis === 'relationship' && !request.goal.text.trim())) throw new APIError('invalid_decision',502);
      const refs = new Set();
      for(const ref of r.evidenceRefs) {
        const values = ref.kind === 'message' ? t.messages : t.activityFacts;
        const key = `${ref.kind}:${ref.id}`;
        if (!values.some((x:any) => x.id === ref.id && x.metric !== "lastSubstantiveMessage") || refs.has(key)) throw new APIError('invalid_evidence',502);
        refs.add(key);
      }
    } else if (d.recommendation !== null || (d.disposition === 'needs_context' ? d.contextRequest === null : d.contextRequest !== null)) throw new APIError('invalid_decision',502);
  }
}
export function validateRanking(expected: string[], output: any): void {
  try { validate('RankingOutput',output); } catch { throw new APIError('provider_invalid_output',502); }
  const ids = output.orderedRecommendationIds;
  if(ids.length !== expected.length || new Set(ids).size !== ids.length || ids.some((id:string) => !expected.includes(id))) throw new APIError('invalid_ranking',502);
}
export function validateRequest(kind: 'assess'|'rank', request: any): void {
  validate(kind === 'assess' ? 'AssessmentRequest':'RankingRequest',request);
  const items = kind === 'assess' ? request.threads : request.recommendations;
  const ids = items.map((x:any) => kind === 'assess' ? x.threadId : x.id);
  if (new Set(ids).size !== ids.length) throw new APIError('duplicate_ids');
  if(kind === 'assess') {
    try { new Intl.DateTimeFormat('en',{timeZone:request.timeZone}); } catch { throw new APIError('invalid_time_zone'); }
    for(const t of request.threads) {
      if((t.contextPass === 'initial' && t.messages.length > 20) || (t.contextPass === 'expanded' && request.threads.length !== 1)) throw new APIError('context_limit');
      if(new Set(t.messages.map((m:any)=>m.id)).size !== t.messages.length || new Set(t.activityFacts.map((f:any)=>f.id)).size !== t.activityFacts.length) throw new APIError('duplicate_evidence');
      for(const m of t.messages) if(new TextEncoder().encode(m.body).length > 2000 || (m.isFromUser && m.readState !== 'unknown') || !t.participants.some((p:any)=>p.id===m.senderId)) throw new APIError('invalid_message');
    }
  }
}
