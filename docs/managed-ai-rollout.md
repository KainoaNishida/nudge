# Managed AI implementation and alpha rollout

The managed pipeline is implemented behind an explicit mode/consent choice on the Mac and a disabled-by-default server rollout flag. It uses local conversation snapshots, independent assessment, and complete AI ranking. The old local-only heuristic mode is still available. Existing direct-Gemini consent and API keys do not authorize the managed data flow.

## Code map

- `Sources/MinderCore/ManagedAIModels.swift`: provider-independent Codable protocol, validation, and bounded text.
- `ManagedMessagesCollector.swift`: read-only per-thread collection, a user-selected 7–180-day metadata scan (50 days by default), daily statistics, read state, and 8/80-message context.
- `ManagedAIStore.swift`: local goals, snapshots, assessments, staged/visible recommendations, feedback, snoozes, mutes, and notification state. Managed state has its own SQLite table; legacy Suggestions and action history remain intact.
- `ManagedAssessmentCoordinator.swift`: resumable scan checkpoints, cache invalidation, one expansion, staging, bounded ranking/merge, and stale-result checks.

The running Mac app scans local Messages every 15 minutes within the selected history window. A scan alone does not call Gemini for every conversation: changed snapshots, expired assessments, and eligible retries enter the cloud queue. Initial excerpts contain at most eight messages; one requested expansion remains capped at 80 within the same window. Assessment batches contain at most four threads. Unchanged `no_action` assessments expire after seven days, while a failed attempted batch waits six hours before another automatic try. Manual Refresh can retry sooner. These limits reduce cost but do not remove the server's $5 per-user monthly cap.
- `ManagedAIClient.swift`: OTP Auth REST client, Keychain sessions, bearer transport, and one retry for a typed transient failure (fresh provider retries are separately charged).
- `Sources/MinderApp/ManagedAISettings.swift`: optional goal, invited sign-in, versioned consent, account deletion, and unmute controls.
- `supabase/functions/nudge-ai`: Edge Function, shared contract, generated TypeScript DTOs, versioned prompts, and Gemini adapter.
- `supabase/migrations/20261001191955_managed_ai.sql`: access, accounting, pricing, atomic reservations, rate/concurrency limits, kill switch, and account-data deletion.

The contract source of truth is `supabase/functions/nudge-ai/contracts/v1.json`. Run `npm run contracts` after an intentional contract/prompt edit. Swift DTOs are checked against the same fixtures; `scripts/check-swift-contract.ts` validates an actual Swift-encoded request. Select assessment and ranking prompt versions independently in `supabase/functions/nudge-ai/prompts/versions.json`; status and response metadata come from that same generated manifest. Version the protocol for incompatible changes. Provider requests and responses also receive semantic membership/permutation validation beyond JSON Schema.

Managed display values are adapted to the existing compact queue/Done views, without writing them to the legacy single-message Suggestions table. Activity evidence and pinned source excerpts stay in the managed store. The queue preserves AI order, places manual items first, and retains the displayed item through reorderings. Opening Messages does not resolve a recommendation. The pixel cat now signals new actionable queue changes with generic text and opens a movable Nudge window. It replaces macOS notifications in this build.

## Verification commands

```sh
npm ci --ignore-scripts
npm run contracts
npm run typecheck
npm test
swift run NudgeChecks
node --experimental-strip-types scripts/check-swift-contract.ts
swift test -Xswiftc -DNUDGE_INTERNAL_DIAGNOSTICS
swift build -c release --product Nudge
```

The backend tests execute the real migration against embedded Postgres (PGlite), not a mocked accounting implementation. They cover reservation/reconciliation, duplicate requests, ambiguous timeouts, caps, concurrency, rate limits, month rollover, access denial, revoked accounts, and client write restrictions. Handler/provider tests use synthetic data and a fake upstream. The provider projects strict contract schemas into Gemini’s generation subset: nullable types and constant enums are preserved; string and array bounds become generation hints and remain mandatory server-side validation. This avoids the live API’s grammar-complexity rejection for nested bounded arrays.

`NudgeChecks` runs without XCTest and exercises contracts, local persistence, read-only source fixtures, busy/quiet threads, mutable reads, unsupported columns, bounded expansion, cache behavior, lifecycle, stale actions, outages, and ranking more than 32 recommendations. The GitHub workflow also uses an Xcode-equipped macOS runner for the existing XCTest suites.

Live model quality is **not** established by deterministic tests. `contracts/fixtures/scenarios.json` contains 40 labeled synthetic scenarios in goal pairs; `ranking-scenarios.json` contains 20 priority comparisons. To run them against a configured development backend:

```sh
# Use an invited synthetic-test account JWT. Do not commit it.
NUDGE_EVAL_URL="https://PROJECT.supabase.co/functions/v1/nudge-ai/v1" \
NUDGE_EVAL_TOKEN="..." \
node scripts/evaluate-ai.mjs .build/ai-evaluation.json
```

Set `NUDGE_EVAL_BATCH_SIZE=4` to also exercise the production batch shape. Optional `NUDGE_EVAL_REFRESH_TOKEN` and `NUDGE_EVAL_PUBLIC_KEY` let long synthetic runs renew their temporary account session without logging credentials. Review every failure and each generated explanation against its supplied local evidence. Set `explanationSupported` for each selected result, add review notes, and set `humanReviewed: true` only after review. Run `node scripts/score-ai-evaluation.mjs .build/ai-evaluation.json`. Gates are at least 85% selection precision, 90% clear-obligation recall, 95% supported explanations, 95% urgent-before-optional comparisons, and correct expanded resolution. These are targets, not current performance claims.

## Provision development, then alpha

Do not reuse an unrelated product's project. Owner configuration still required:

1. Two Supabase project refs, one development and one alpha, in the selected organization.
2. A paid Gemini project API key, restricted to the Gemini API as appropriate.
3. A verified sending domain and Resend SMTP credentials; the sender address/name.
4. Owner/tester emails to pre-provision, plus Developer ID/notarization configuration for distribution.

Discover CLI flags with `node_modules/.bin/supabase <command> --help` before deployment. Link the intended development project, review/apply the migration, deploy `nudge-ai`, and set `GEMINI_API_KEY` using Supabase secret storage. Repeat for alpha only after development passes the gates. Never place provider/service-role keys in the Mac bundle, `.env.example`, or source control.

`supabase/config.toml` disables public registration with `[auth].enable_signup = false`, keeps the email provider enabled with `[auth.email].enable_signup = true`, configures short-lived access tokens, and selects the code-only email template. The email-specific setting controls the provider in the deployed CLI/Auth version: disabling it also blocks existing users from signing in. A live `/auth/v1/settings` read-back verified `external.email = true` and `disable_signup = true`. Apply the equivalent settings to **each remote project**; local config alone does not change hosted Auth. Use Resend's `smtp.resend.com`, TLS port 465, username `resend`, and the SMTP/API password in backend configuration. Configure a verified sender address. Supabase's default mail sender is unsuitable for general testers. [Supabase SMTP setup](https://supabase.com/docs/guides/auth/auth-smtp).

Pre-create approved Auth accounts with the Admin API (do not send unsolicited invitations). Add each approved Auth user UUID to `public.nudge_memberships`. The Mac uses email OTP with `create_user: false`; every inference also checks current membership on the server. Clients have no SQL/RPC privileges for access or accounting. Do not add permissive policies to these tables.

`verify_jwt = false` disables only the legacy Edge gateway verifier. The function itself requires a bearer token and verifies it against Supabase Auth on **every** route. It obtains user identity exclusively from that verification and uses service credentials only inside the function. DELETE first removes membership/data, then revokes Auth sessions and deletes the Auth user. Existing JWTs cannot infer after membership removal. Anonymous aggregate global spending remains, with no user identity.

Enable the development rollout explicitly after setup:

```sql
update public.nudge_config set rollout_enabled = true where id = true;
```

Pause inference immediately with:

```sql
update public.nudge_config set kill_switch = true where id = true;
```

Leave alpha rollout disabled until synthetic evaluations, owner testing, and packaged checks pass. The model is selected by `nudge_config.model`, never a normal user setting. Any change requires new pricing configuration and evaluation.

## Pricing and operational constraints

User limit: $5 per UTC calendar month. Global default: $100 per UTC calendar month, configurable through `nudge_config.global_cap_microusd`. Hosting, SMTP, and other infrastructure costs are separate.

All reservation/reconciliation operations acquire the same short config-row lock and atomically update user/global monthly totals. Reservations use a conservative UTF-8 input bound (including schema/prompt framing) and 8,192 billable output tokens including thinking. The Interactions request applies the same output cap; the provider documents it as a combined hard limit. Usage reconciliation counts visible output plus thinking. [Gemini thinking and token limits](https://ai.google.dev/gemini-api/docs/thinking).

The initial pricing record is $0.75/M input and $3.75/M output, effective through December 31, 2026, for paid Gemini 3.8 Flash. It expires January 1, 2027; inference fails closed until the owner installs reviewed effective pricing. [Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing). Do not silently extend the expiration date.

The Mac spaces inference requests to stay below the server rate limit and persists completed ranking/merge passes for retry after interruption. Requests have a 90-second provider timeout, two in-flight calls per account, and twelve accepted requests per minute. Expired reservations retain their conservative charge and stop occupying concurrency slots after three minutes. Duplicate request IDs return `request_in_progress` or `response_not_replayable`; responses are never stored. A fresh transient retry is separately reserved and charged. There is no retry loop for malformed output. If budget cannot reserve the next request, coverage may stop before the nominal remaining allowance reaches zero.

No application logging includes prompts, goals, bodies, explanations, provider error bodies, or auth tokens. The database has only membership, consent version, prices, request status and token/spending metadata. Audit platform logging configuration during deployment as well. Stateless Gemini Interactions use `store: false`, no tools and no history chaining. This disables stored interaction objects, not all provider operational retention. [Interactions data handling](https://ai.google.dev/gemini-api/docs/interactions-overview).

## Build and packaged-app checks

Use separate public URL/publishable-key values for development and alpha:

```sh
NUDGE_SUPABASE_URL="https://PROJECT.supabase.co" \
NUDGE_SUPABASE_PUBLISHABLE_KEY="sb_publishable_..." \
scripts/build-dev-app.sh
```

The packaging scripts embed only these public values into Info.plist before signing. They reject secret/service-role keys. `scripts/build-alpha-dmg.sh` accepts the same variables and the existing signing/notarization configuration. With no configured service, the app still builds and explains that managed sign-in is not configured.

Before inviting testers, verify with the packaged app:

- An invited email receives a code; an uninvited address cannot create an account. Session survives restart using Keychain; sign-out and account deletion work.
- Fresh consent is required even on an upgrade with old direct-Gemini consent. Switching local-only prevents managed uploads.
- Goal text and revision survive restart; a changed goal marks old results and schedules reassessment.
- Long explanations and evidence remain readable in the compact card; message/activity evidence matches local source data. Numeric confidence is not displayed.
- Direct/group Open in Messages works on the supported macOS version; opening alone never marks Done. Group navigation relies on Messages' currently observed URL behavior and requires packaged verification.
- Done, Undo, Not useful, mute/unmute and all snooze options survive restart. New incoming activity cannot end a snooze; relationship Done lasts at least 14 days while a new explicit obligation can still be assessed.
- Immediate/hourly/daily/quiet and quiet hours behave correctly in the user's time zone. Only new supported follow-through items notify; reranking/rewording and optional check-ins do not.
- Disconnect network, revoke access, exhaust development quota and fail a batch/rank: the previous queue remains and analysis details report incomplete coverage.
- Upgrade a copy of the existing database; confirm manual items, terminal Suggestions and Done history survive. Local deletion clears managed derived data too.

Do not enable alpha based only on a successful compilation. Real sign-in/email delivery, live provider output, human model evaluation, and packaged Messages/pixel-cat behavior are release prerequisites.

## Verification status for this implementation

- 19 backend/contract/Postgres tests pass locally; TypeScript checking and generated-contract consistency pass.
- The standalone Swift checks pass, including database upgrades, preserving legacy queue items, cross-language encoding, unchanged caching, context limits, read updates, stale goal/account/consent/action rejection, notification identity, 14-day recurrence, and a 41-item ranking/merge.
- The development app was rebuilt and its ad-hoc code signature verified.
- Full XCTest execution is blocked on this Mac by the command-line toolchain lacking the XCTest module; the Xcode CI job is configured but has not run here.
- Desktop UI automation times out. Owner sign-in and consent are confirmed from local app state; packaged layout, navigation and notification timing still require the manual checks above.
- The owner-approved development project is now deployed: `nudge-development` (`dsqvtxalptmgwpilffxz`), US West, in the existing organization. The migration and `nudge-ai` function are installed. An unauthenticated status request returns HTTP 401. Database advisors report only the expected informational notices for backend-only RLS tables without client policies.
- Development rollout is enabled for the sole owner membership; broader alpha access remains unprovisioned. The owner Auth account and active membership are provisioned; public registration is disabled and six-digit codes expire after ten minutes, with fifteen-minute access tokens. A read-back confirmed all declared Auth changes were applied. The approved Gemini key is installed in backend secrets. A real synthetic assessment returned HTTP 200 and reconciled $0.001850 of usage; The code-email template and Resend SMTP are installed. After the owner replaced an initially rejected SMTP key, the live owner OTP request succeeded with HTTP 200. The owner subsequently signed in and accepted managed AI, confirmed by the local app state. The latest live synthetic evaluation using `assess-v2` / `rank-v1` returned 40/40 expected dispositions, 13/13 correctly selected recommendations, 12/12 clear obligations, successful resolution in both expansions, and 20/20 correct priority comparisons. This run cost $0.074223. Human evidence review remains incomplete; review relative-date wording before tester rollout. Results are in ignored `.build/ai-evaluation.json`, with an evidence review sheet in `.build/ai-evaluation-review.md`. The scorer must not be represented as passing the human-review gate. No successful owner conversation inference had been recorded at that setup checkpoint.

## Owner development setup (October 1, 2026)

The owner selected their existing Supabase organization and owner-only testing with `kainoanishida@gmail.com`. Supabase quoted $0/month for this development project. A separate alpha project is deferred until tester rollout. Hosted configuration rejected the custom code-email template with HTTP 400: free projects using the default sender cannot modify email templates. Custom SMTP is therefore needed even for this owner's code-based sign-in. Resend's `onboarding@resend.dev` test sender can deliver only to the email on the Resend account; configure a verified domain before inviting other testers. The owner signed into Resend and created a sending-only key named `Nudge development sign-in`. Supabase SMTP is saved with the correct host, port, username, and test sender. The code-only email template is installed. After an initial SMTP 535 rejection, the owner replaced the key and the sign-in email request succeeded with HTTP 200. The key remains in Supabase Auth configuration; no key is committed.

The existing Google AI Studio project named `Minder` is shown on paid Tier 1 with prepay billing. The owner chose to finish Gemini setup and approved reusing its key in Nudge backend secret storage. The key has been installed and live synthetic assessments and rankings succeeded. No provider key is bundled with the app. API billing is distinct from consumer subscriptions, and Nudge's planned backend uses owner-funded API usage with a server-enforced $5/user monthly allowance.

Supabase's official CLI is now authenticated locally as `nudge-development-setup`. It was used after dashboard controls failed to respond; credentials were not committed or printed. The temporary `.build/owner-auth-config` applied the authentication restrictions without a custom email template. After SMTP setup, apply the full `supabase/config.toml`; the email template path must be relative to the workspace root (`./supabase/templates/email-code.html`).

The development app's public configuration is saved in the ignored `.build/nudge-development.env` file. To preserve this service connection on later development builds:

```sh
source .build/nudge-development.env
scripts/build-dev-app.sh
```

Only the service URL and public publishable key belong in this file or the Mac bundle. Store `GEMINI_API_KEY` only in the Nudge project's Supabase Edge Function secrets.

Owner sign-in and the updated managed-AI disclosure are complete, confirmed from the app's local account and consent state. The code-email template has already been applied using `.build/code-email-config`. Desktop UI automation still times out; packaged layout and navigation checks remain manual.

The first owner refresh exposed senderless Messages system events. Those events were preserved in the excerpt but lacked a matching participant, so backend validation rejected the batch as `invalid_message`. Initial and expanded contexts now include an explicit unknown participant for every otherwise-unrepresented sender, preserving system-event and unavailable-content flags. Synthetic source fixtures exercise both paths and their Swift JSON passes the actual backend validator. The refresh coordinator preserves the original failure instead of replacing it with a stale-source error from untouched prior recommendations. The main window now shows live progress and failure details. The standalone Swift checks, cross-language validation, development app build, and code-signature verification pass after these fixes.

A live CPU sample also identified main-thread stalls during managed-state decoding: the custom date decoder created fresh ICU formatters for every timestamp. Reusable ISO 8601 parsing now handles whole seconds, fractional seconds, and offsets. The regression check decoded 30,000 synthetic history dates in 0.033 seconds on the development Mac; all Swift checks pass with the new parser.

After the responsiveness rebuild, the live refresh reached local source collection and reported `authorization denied` opening Messages read-only. The owner must re-enable Full Disk Access for the current development app, reopen it, and refresh before the live inference check can complete. Existing queue and history are retained.

On the subsequent owner refresh, repeated macOS Keychain dialogs were traced to a new `ManagedAIClient` reading the saved sign-in session for every status, assessment, and ranking call. The running app now shares one locked, in-memory session cache across Settings and refresh clients. Successful token rotation updates it; sign-out clears it; failed reads/writes never install unpersisted credentials. Synthetic checks cover repeated and concurrent loads, replacement, removal, and failures. The development app was rebuilt and its signature verified. Because development builds currently use ad-hoc signing and this Mac has no valid code-signing identities, macOS can require reauthorization when the app binary changes. Do not change the Keychain item to allow all applications; authorize this Nudge build only. [Apple Keychain reauthorization](https://support.apple.com/guide/keychain-access/if-a-trusted-app-asks-for-keychain-access-kyca1331/mac).
