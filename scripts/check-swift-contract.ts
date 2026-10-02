import fs from 'node:fs';
import {validateRequest} from '../supabase/functions/nudge-ai/contracts.ts';
for(const file of ['swift-contract-request','swift-sender-request','swift-expanded-sender-request']) {
 validateRequest('assess',JSON.parse(fs.readFileSync(`.build/${file}.json`,'utf8')));
}
console.log('Swift wire requests, including senderless system events and expanded context, conform to the backend contract.');
