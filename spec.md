# Shudo overnight performance, quality, and visual refinement spec

Date: 2026-07-22  
Repository: `/Users/luke/code/personal/shudo`  
Target branch: `main`  
Owner acceptance: Luke will QA the finished app on his iPhone in the morning.

## Mission

Run a deep, end-to-end improvement pass over Shudo. Find and implement high-confidence changes that make meal capture, upload, analysis, image display, navigation, and perceived responsiveness as fast and polished as this architecture can reasonably support without sacrificing correctness, privacy, reliability, or nutrition-result quality.

This is an implementation assignment, not just an audit. Inspect the whole repository, measure or otherwise establish evidence, implement worthwhile improvements in coherent batches, test them, commit them directly to `main`, and push `main` to `origin` as progress becomes trustworthy. Continue the review-and-improve loop until another pass yields no meaningful, safe improvement.

Use as many sub-agents as useful. Assign bounded workstreams, have the lead agent independently inspect and integrate their findings, and avoid simultaneous edits to the same files. The lead agent owns architecture decisions, final diffs, verification, commits, and pushes.

## Product and architecture context

Shudo is a small, currently single-user, voice-first nutrition log:

- `shudo/` is the SwiftUI iPhone app.
- `shudoTests/` and `shudoUITests/` cover native behavior.
- `supabase/functions/` contains authenticated Edge Functions and the OpenAI pipeline.
- `supabase/migrations/` contains PostgreSQL schema, RLS, durable claims, leases, quotas, and retry fencing.
- `shudo-web/` is a read-only Next.js history companion and public auth/support surface.
- `scripts/verify-release.zsh` is the full release gate.
- `scripts/install-ios-device.zsh` builds, installs, launches, and verifies a signed Release build on Luke's paired phone.
- `README.md`, `docs/morning-handoff.md`, and `docs/ios-release-readiness.md` explain current production and release constraints.

The main capture path is:

1. `EntryComposerView` gathers text, audio, and up to four selected photos.
2. `ImageProcessor` downscales photos and currently creates one upload collage.
3. `APIService.createEntry` materializes a multipart request containing text, audio, and the image.
4. `create_entry` authenticates, validates, reserves an idempotent row, uploads attachments, publishes the durable capture, and dispatches `process_entry`.
5. `entry_processor` may download/transcribe audio, signs the image, calls the OpenAI Responses API with strict structured output and streaming, publishes a short analysis preview, and atomically completes the entry.
6. `TodayViewModel` shows an optimistic entry and polls Supabase until the durable result completes or fails.
7. `SupabaseService` lists/fetches entries and signs private image paths; SwiftUI `AsyncImage` displays them.

The current analysis stack intentionally uses `gpt-4o-transcribe`, `gpt-5.6-sol`, `store: false`, strict JSON Schema, low reasoning effort, a safety identifier, durable retries, private Storage, and fenced writes. Preserve these properties unless an evidence-backed alternative is clearly better and compatible with the current official provider documentation.

## Outcomes

Optimize both real and perceived performance:

- The composer should stay responsive while selecting, decoding, downsampling, collaging/encoding, and submitting multiple large photos.
- One photo, several photos, long text, voice plus photos plus text, and two captures submitted in quick succession should all behave correctly.
- The time from tapping **Log meal** to the sheet dismissing/optimistic row appearing should feel immediate.
- The time to durable server acceptance should be minimized.
- The time to useful progress text and the final nutrition result should be minimized without degrading estimate quality.
- Existing and newly completed meal images should appear quickly, avoid flicker and unnecessary network work, and remain private.
- Repeated foregrounding, day changes, pull-to-refresh, correction, retry, and concurrent processing should not cause request storms, stale UI, duplicated work, or regressions.
- UI hierarchy, spacing, rules/borders, radii, typography, states, and motion should feel intentional and consistent throughout native and web surfaces.
- Accessibility, Dynamic Type, Reduce Motion, contrast, touch targets, VoiceOver labels, and narrow-screen behavior must remain first-class.

Do not claim a speedup from code shape alone. Add targeted measurements or instrumentation where useful, compare before/after for important hot paths, and record what was actually observed. When a realistic provider round trip cannot be benchmarked safely, distinguish local measurements, architectural inference, and unverified hypotheses.

## Required scenarios

Exercise or cover these cases with tests, focused harnesses, simulator checks, or safe manual verification as appropriate:

1. Text only: short description.
2. Text only: description near the 12,000 UTF-16-unit client/server limit.
3. One large portrait photo.
4. Four large mixed-orientation photos, plus investigation of whether supporting five separately or through a different representation is worthwhile. Do not increase the limit casually if it worsens latency, cost, or accuracy.
5. Voice only near the normal practical duration.
6. Voice + several photos + substantial text.
7. Two submissions started in quick succession.
8. Two entries simultaneously transcribing/analyzing, including polling and preview updates.
9. App background/foreground during upload or analysis.
10. Interrupted upload, dispatch failure, stale lease, retry, and idempotent replay.
11. Day history containing many photo-backed meals.
12. Opening an entry detail immediately after completion and again from cached history.
13. Correction/reanalysis with and without retained photo context.
14. Slow network, temporary network loss, provider timeout, and provider/server errors.
15. Large Dynamic Type, Reduce Motion, VoiceOver-relevant labels, and smallest supported iPhone width.

## Workstream A: establish a baseline and observability

Before broad implementation:

- Read the repository and recent history; do not rely only on this spec.
- Run the fastest relevant current tests and record baseline status.
- Map latency into explicit stages: local media preparation, request construction, upload, durable acceptance, worker dispatch/cold start, Storage download/signing, transcription, OpenAI time-to-first-useful-preview, model completion, database finalization, client detection, and image fetch/render.
- Prefer lightweight signposts, structured duration fields, server timing, or focused benchmark tests that do not leak meal content or credentials.
- Avoid noisy permanent logging. Never log raw notes, transcripts, image URLs with signatures, JWTs, API keys, or private user data.
- Create or update `docs/overnight-audit.md` with baseline evidence, accepted/rejected hypotheses, changes, observed results, tradeoffs, and remaining opportunities.

## Workstream B: native capture and upload performance

Inspect at least:

- `shudo/Views/EntryComposerView.swift`
- `shudo/Services/ImageProcessor.swift`
- `shudo/Services/APIService.swift`
- `shudo/Services/AudioRecorder.swift`
- `shudo/ViewModels/TodayViewModel.swift`

Investigate and improve where evidence supports it:

- Main-actor work during JPEG encoding, collage rendering, audio reads, multipart construction, and large `Data` copies.
- Serial photo loading/downsampling versus bounded concurrency, cancellation, ordering, memory pressure, and autorelease behavior.
- Preparing upload-ready encoded data earlier so the submit tap does not trigger a visible CPU/memory spike.
- Multipart body materialization versus a streaming/file-backed upload design, balanced against complexity and retry behavior.
- Image pixel size, JPEG quality, orientation normalization, metadata stripping, visual legibility, upload bytes, and model latency/accuracy.
- Whether one collage is the best representation for several images. Compare distinct images, collages, grids, and selective detail levels against payload size, OpenAI input cost/latency, schema/Storage changes, display requirements, and estimate quality. Do not assume “more images” is automatically better.
- Optimistic UI and composer dismissal semantics. A capture must not appear accepted until the server has durably accepted it, but local preparation and presentation should feel immediate.
- Cancellation and retry behavior when the picker/composer disappears or a second request starts.
- Reuse of a configured `URLSession`, request priority, caching policy, connection reuse, timeout layering, and correct handling of constrained/expensive networks.
- Peak memory with multiple modern iPhone photos and audio in one capture.

Add regression tests for any extracted policies, concurrency controls, size decisions, cancellation behavior, and request construction that can be tested deterministically.

## Workstream C: backend and OpenAI critical path

Inspect at least:

- `supabase/functions/create_entry/index.ts`
- `supabase/functions/process_entry/index.ts`
- `supabase/functions/_shared/dispatch.ts`
- `supabase/functions/_shared/entry_processor.ts`
- `supabase/functions/_shared/analysis.ts`
- `supabase/functions/_shared/analysis_preview.ts`
- `supabase/functions/_shared/responses_stream.ts`
- capture, quota, retry, correction, onboarding, and summary helpers
- the relevant RPCs and indexes in `supabase/migrations/`

Investigate and improve where justified:

- Sequential Storage operations and avoidable calls on the upload-to-dispatch path.
- Nested Edge Function dispatch overhead, cold starts, durable acceptance timing, and recovery guarantees.
- Unnecessary downloads, signs, database reads/writes, cleanup calls, or duplicated auth work.
- Preview publication cadence and write amplification. Preserve useful early feedback without a write per insignificant token/chunk.
- Text truncation and normalization costs and whether long inputs carry redundant context.
- OpenAI request design: instruction clarity, input ordering, strict schema size, output-token cap, verbosity, reasoning effort, image detail choice, and streaming behavior.
- Time-to-first-useful-field from the strict JSON stream. The preview-first schema ordering is intentional; improve only with tests.
- Transcription prompt and meal-analysis prompt accuracy, especially brands, portions, sauces, mixed dishes, multiple photos, conflicts between text/voice/image, uncertainty, and corrections.
- Internal consistency between item macros, calories, and totals. If adding deterministic validation/reconciliation, keep the model output honest and do not manufacture false precision.
- Whether official OpenAI features can improve grounding or latency for this use case. Consult current official OpenAI documentation before changing API fields, model names, image input formats, reasoning controls, caching, or structured output behavior. Do not introduce web search into ordinary meal estimation unless there is a strong, measured quality case and bounded privacy/cost behavior.
- Concurrent submissions, quota reservation, idempotency, claims, leases, fencing, and retry exhaustion under races.
- Database query plans and indexes for the actual entry/day/status paths.

Hard constraints:

- Never expose OpenAI or Supabase service credentials to the client.
- Keep `store: false` and private media semantics.
- Preserve RLS, owner checks, durable idempotency, quota enforcement, fenced retries, raw-audio cleanup, and account deletion.
- Never use Luke's real meal history as destructive test data.
- Do not edit an already-applied migration in place. Add a new forward migration if schema/index work is genuinely needed, and update release verification deliberately.
- Keep nutrition output framed as an estimate, not medical, allergy, or emergency advice.

## Workstream D: client refresh, caching, and image display

Inspect at least:

- `shudo/Services/SupabaseService.swift`
- `shudo/ViewModels/TodayViewModel.swift`
- `shudo/Views/Components/EntryCard.swift`
- `shudo/Views/EntryDetailView.swift`
- profile-photo loading and the web meal list

Investigate and improve where justified:

- Per-entry polling frequency, backoff, cancellation, duplicate fetches, status-only projections, and multiple simultaneous entries.
- Whether Supabase Realtime, batched polling, or another event-driven mechanism is worth its complexity for this small app. Prefer the simplest measurable win.
- Re-signing private image URLs during list loads and every status poll, including avoidable signing for unchanged entries.
- Batch signing, longer safe expirations, in-memory URL caching keyed by path/expiry, decoded-image caching, thumbnail strategy, request coalescing, and list/detail cache reuse.
- `AsyncImage` flicker, cancellation, downsample-to-render-size behavior, failure/retry presentation, and full-resolution detail loading.
- Redundant date formatter/ISO formatter construction and other frequently repeated allocation in render/parse paths.
- Load generation, foreground reconciliation, day switching, target history, and avoiding stale results.
- Query projection size and whether processing polls fetch fields/images they do not need.

Maintain private Storage access and robust expiration handling. Never turn the meal-image bucket public for speed.

## Workstream E: UI and interaction quality

Perform a deliberate visual audit of every native screen and meaningful state, plus the read-only web companion. Use simulator screenshots/previews and browser rendering where possible rather than reviewing code alone.

Review:

- Today, empty/loading/processing/failed/completed states, composer, multi-photo selection, detail, correction, onboarding, profile editor, account/settings, auth, weekly insights, heatmap, trends, web dashboard/history, and public support/terms/auth pages.
- Spacing rhythm, alignment, hierarchy, readable line lengths, safe-area behavior, keyboard behavior, sheet heights, scroll endings, and touch targets.
- Borders/rules: eliminate accidental double rules, inconsistent opacity/width, clipped strokes, or borders that create visual noise. Keep rules where they clarify grouping.
- Corner-radius vocabulary: extend the design system if useful instead of scattering near-duplicate values.
- Typography, truncation, monospaced numbers, titles, captions, and long generated text.
- Color/contrast across Studio, Carbon, and Oxide themes.
- Image aspect treatment: thumbnails may crop, but detail and multi-photo review must keep all useful food content discoverable.
- Loading shimmer, typewriter/preview animation, completion reveal, and shadows for smoothness, battery use, and Reduce Motion behavior.
- Duplicate or accidental source modifiers/content introduced by recent polish work.
- Dynamic Type layout, VoiceOver order/labels, accessibility values, and focus behavior.
- Consistency between native and web without forcing them into identical platform conventions.

Prefer restrained, cohesive refinement over a redesign. Preserve the current dark, tactile Shudo character and core navigation. Do not add decorative complexity that slows rendering or obscures nutrition information.

## Workstream F: broader quality-of-life review

Inspect every remaining corner for small, high-value improvements:

- Authentication/session refresh behavior and first meaningful screen latency.
- Error copy that tells the user what happened and whether work is continuing safely.
- Retry, correction, deletion, background recovery, offline behavior, and progress communication.
- Onboarding analysis/prompt quality and latency.
- Weekly summary generation and display.
- Web server/client boundaries, data fetch waterfalls, bundle size, image behavior, and mobile layout.
- Build warnings, dead code, duplicate code, stale comments, and fragile tests.

Do not expand product scope into subscriptions, social features, analytics, medical advice, or a broad redesign.

## Prioritization and change standard

Use this order:

1. Correctness, privacy, security, and data integrity.
2. Measurable end-to-end latency and responsiveness.
3. Reliability under concurrency, retries, and app lifecycle changes.
4. Perceived performance and clear progress.
5. Nutrition-result quality and prompt clarity.
6. Visual polish, accessibility, and quality of life.
7. Maintainability that enables or protects the above.

Implement changes when the benefit is supported and risk is controlled. For attractive ideas with weak evidence, document and reject/defer them. Avoid dependency churn and architectural rewrites unless they solve a demonstrated bottleneck. Keep the app lean for one user while using production-quality engineering where data loss, privacy, or paid model calls are involved.

## Verification

Use focused tests during each batch, then run the broadest feasible release checks before the final push:

- Native unit and UI tests for changed areas.
- Deno format, lint, check, and Edge Function tests.
- Database migration tests when database behavior changes.
- Web tests, lint, typecheck, production build, and dependency audit when web code changes.
- `git diff --check` and compiler warnings as errors.
- `scripts/verify-release.zsh` for the final integrated state if prerequisites remain available.

Add tests that prove important race, parsing, prompt-contract, cache, cancellation, and state-transition behavior. Do not weaken tests or release gates to make a change pass. If an external prerequisite prevents one check, run all unaffected checks and document the exact blocker and residual risk.

For UI changes, capture a small before/after screenshot set or clearly document simulator/device observations in `docs/overnight-audit.md`. Avoid committing bulky derived artifacts.

## Git and deployment protocol

- Work directly on `main` as explicitly authorized.
- Start by checking `git status`, current branch, recent commits, and `origin/main`.
- Preserve any unexpected user changes. Do not reset, discard, or overwrite them.
- Make small, coherent commits after focused verification. Use descriptive commit messages.
- Push each trusted milestone to `origin main`; do not force-push.
- Before each push, fetch and reconcile any remote advance safely, rerun affected checks, then push.
- Never commit secrets, local environment files, signed URLs, build products, personal meal content, or credentials.
- Do not deploy Supabase/Vercel production or alter hosted data merely because code was pushed. Only use already-established automatic behavior. Record any deployment needed for a backend change in the morning handoff.
- At the very end, if Luke's paired iPhone is connected, unlocked, trusted, and all native verification passes, it is acceptable to run `scripts/install-ios-device.zsh` so morning QA begins on the finished Release build. If the phone is unavailable, do not treat that as a code blocker; document it.

## Required deliverables

1. Implemented, tested improvements committed and pushed to `origin/main`.
2. `docs/overnight-audit.md` containing:
   - architecture/latency map;
   - baseline and after evidence;
   - findings ranked by impact/confidence/risk;
   - implemented changes and tradeoffs;
   - rejected/deferred ideas and why;
   - test and release results;
   - production deployment needs, if any;
   - concise morning phone QA checklist.
3. Updated tests and documentation for changed behavior.
4. A final agent message summarizing commit hashes, pushes, observed wins, verification, residual risks, whether the phone received the build, and exactly what Luke should test first.

## Completion loop

After the first integrated pass:

1. Re-read this spec and the full diff.
2. Review the app again as a user, not just as an implementer.
3. Re-run targeted profiling/searches for remaining bottlenecks and visual inconsistencies.
4. Ask sub-agents for adversarial review of performance claims, race safety, prompt quality, accessibility, and visual coherence.
5. Fix high-confidence findings, verify, commit, and push.
6. Repeat until the remaining list contains only low-value, speculative, risky, externally blocked, or out-of-scope ideas.

Do not stop at a list of suggestions. Do not make speculative changes merely to stay busy. Finish with a clean worktree, a green or honestly documented verification state, and `main` pushed.
