import fs from 'node:fs';
const defs = JSON.parse(fs.readFileSync('supabase/functions/nudge-ai/contracts/v1.json')).$defs;
function type(s) {
  if(s.$ref) return s.$ref.split('/').pop();
  if(s.anyOf) return s.anyOf.map(type).join(' | ');
  if(s.const !== undefined) return JSON.stringify(s.const);
  if(s.enum) return s.enum.map(x=>JSON.stringify(x)).join(' | ');
  if(s.type === 'object') return '{ '+Object.entries(s.properties).map(([k,v])=>`${k}: ${type(v)}`).join('; ')+' }';
  if(s.type === 'array') return `Array<${type(s.items)}>`;
  return ({integer:'number',null:'null'})[s.type] ?? s.type;
}
const output = '// Generated from contracts/v1.json. Run npm run contracts.\n'+Object.entries(defs).map(([k,v])=>`export type ${k} = ${type(v)};`).join('\n')+'\n';
const path = 'supabase/functions/nudge-ai/dto.ts';
if(process.argv.includes('--check')) { if(fs.readFileSync(path,'utf8')!==output) throw Error('Contract types are out of date'); }
else fs.writeFileSync(path,output);
const versions=JSON.parse(fs.readFileSync('supabase/functions/nudge-ai/prompts/versions.json','utf8'));
for(const kind of ['assess','rank']) if(!new RegExp(`^${kind}-v[1-9][0-9]*$`).test(versions[kind]))throw Error('Invalid prompt version');
const promptOutput = '// Generated from versioned prompt files.\nexport const promptVersions = '+JSON.stringify(versions,null,2)+';\nexport const prompts = '+JSON.stringify(Object.fromEntries(['assess','rank'].map(k=>[k,fs.readFileSync(`supabase/functions/nudge-ai/prompts/${versions[k]}.txt`,'utf8')])),null,2)+';\n';
const promptPath='supabase/functions/nudge-ai/prompts.ts';
if(process.argv.includes('--check')) {if(fs.readFileSync(promptPath,'utf8')!==promptOutput)throw Error('Generated prompts are out of date');}else fs.writeFileSync(promptPath,promptOutput);
