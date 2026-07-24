# Shudo overnight audit — 2026-07-23

Autonomous overnight performance, quality, and visual refinement run per `spec.md`.
Working directly on `main`; each batch is committed after focused verification.

## Baseline (recorded before any change)

| Check | Result | Notes |
| --- | --- | --- |
| Deno `fmt --check`, `lint`, `check` (all functions) | PASS | |
| Deno function tests (`deno test`) | PASS | |
| Native unit tests (`xcodebuild test`, iPhone 17 Pro sim, warnings-as-errors) | PASS | ~14 s test phase |
| Web tests/lint/typecheck/build | PASS | 45 tests; `npm ci` realigned Next 16.2.10→16.2.11 |
| Worktree | clean at `fc19b0e`, synced with `origin/main` | |

## Final verification (after all changes)

| Check | Result | Notes |
| --- | --- | --- |
| `scripts/verify-release.zsh` (full gate) | **PASS** | migration hashes, script guards, web ci/test/lint/typecheck/build/audit, authenticated Vercel snapshot pull/build/dry-deploy manifest, Deno fmt/lint/test/check, fresh + legacy-restore PostgreSQL shapes, native unit **and UI** tests (125 passed / 0 failed, warnings as errors), `verify-ios-release.zsh` unsigned device Release + privacy metadata |
| Deno function tests | PASS (69) | includes new `withTimeout` tests |
| Web suite | PASS (45 tests, lint, typecheck, prod build) | |
| Native suite | PASS (125 incl. UI tests) | new tests: token-response user-id, upload encoding, signed-URL cache expiry + sign-out epoch, batch-sign parsing, status-snapshot parse/merge, radius tokens |
| Device install (`install-ios-device.zsh`) | **NOT COMPLETED — phone unavailable** | The paired iPhone showed `unavailable` (locked/asleep) at 09:30; the guarded installer refused, by design. Everything is verified up to signing. In the morning: unlock the phone, keep it connected, run `scripts/install-ios-device.zsh` (~2 min). |

Gate environment note: run the gate as `LC_ALL=en_US.UTF-8 ./scripts/verify-release.zsh`
from a non-interactive shell — Postgres 17's throwaway server refuses to start
without a locale ("postmaster became multithreaded during startup").

Production deployment needed to activate tonight's backend/web changes (not
performed overnight, per guardrails): `scripts/deploy-supabase-production.zsh
--apply` (Edge Functions only; **no new migrations**) and
`scripts/deploy-vercel-production.zsh --apply`. Until the Supabase deploy, the
app runs against the previous Edge Functions — fully compatible: every native
change degrades gracefully (batch signing falls back per-path; polling
projection and multipart contract are unchanged server-side).

Toolchain: Xcode 26.6 (via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`;
system `xcode-select` points at CommandLineTools), Deno 2.9.3, Node 24.16, Supabase CLI
2.109.1, psql 17.10. Luke's iPhone 17 Pro connected via `devicectl`.

## Architecture / latency map (capture → result)

Stages, owner, and the main costs observed by reading the code:

1. **Photo selection → prepared UIImage** (`EntryComposerView.preparePickedImages`)
   — serial `loadTransferable` per item, ImageIO downsample to 1600 px off-main.
2. **Submit tap → request ready** (`submit()` + `APIService.makeMultipart`)
   — `ImageProcessor.collageForUpload` runs synchronously **on the main thread**
   at tap time (per-image CIContext + full-size renders); then `jpegData(from:)`
   re-renders the already-sized collage a second time inside `createEntry`
   (off-main; Swift 5 mode, no default MainActor isolation on `APIService`).
3. **Upload → durable acceptance** (`create_entry`)
   — `authenticate()` = GoTrue `getUser` network RTT **serially before** form
   parse; image and audio Storage uploads run **sequentially**; then
   `publish_entry_upload` RPC; dispatch via `EdgeRuntime.waitUntil` (does not
   block the 202).
4. **Worker start → analysis start** (`process_entry` / `entry_processor`)
   — claim RPC, row fetch, audio download + transcription (voice), fenced
   transcript update, audio detach RPC, image sign (600 s), all sequential.
5. **OpenAI stream → preview → completion** (`analysis.ts`, `responses_stream.ts`)
   — `gpt-5.6-sol`, strict JSON schema with `analysis_preview` first, low
   reasoning effort, `store:false`, preview published at most every 500 ms
   (client polls at 650 ms, so up to ~40% of preview writes are never observed).
6. **Client detection** (`TodayViewModel.poll`)
   — full-row fetch (`entryListColumns` incl. `raw_text` ≤ 12 KB) every 650 ms
   while `analyzing`, backoff to 3 s otherwise; per-entry task.
7. **Image display** (`SupabaseService.fetchEntries` + `AsyncImage`)
   — every day load re-signs every image path individually (POST per path,
   `expiresIn: 600`); each refresh mints a *different* signed URL for the same
   path, so `AsyncImage` treats it as a new resource → guaranteed re-download +
   placeholder flicker on every refresh/foreground; detail view signs the same
   path yet again.

## OpenAI verification (2026-07-23, developers.openai.com)

- gpt-5.6 family uses **32×32-px patch tokenization**; `detail:"high"` caps the
  patch budget (5.5 documented at 2,500 patches / 2048 px; 5.6 supports
  low/high/original/auto and `auto`≡`original` = *no* resizing cap).
- The legacy "shortest side → 768 px, 512-px tiles" rule does **not** apply to
  gpt-5.6. A 1600×1600 collage ≈ 50×50 = 2,500 patches — at/near the high-detail
  budget; each cell of a 4-photo collage keeps ~625 patches of real detail.
- Consequence: the single 2×2 collage at 1600 px with `detail:"high"` is a good
  cost/latency bound (separate images would ~4× image prefill cost). **Keep
  collage representation; keep `detail:"high"`; keep 1600 px.** Rejected:
  per-photo image inputs (cost/latency, schema+storage churn, no measured
  quality gap), `detail:"original"`/`auto` (uncapped patch cost on 5.6).

## Punch list (living)

Statuses: `[ ]` open · `[x]` done · `[-]` rejected/deferred (reason inline).

### P1 — correctness/latency, high confidence
- [x] B1. Pre-encode upload JPEG off-main as photos change; submit awaits the
  prepared bytes instead of rendering on the tap (`fa6e795`).
- [x] B2. Collage encoded directly (no second full-size render); shared
  `CIContext` for orientation normalization (`fa6e795`).
- [x] B3. `create_entry` uploads run in parallel; `authenticate()` overlaps
  form parsing; storage calls bounded by timeouts (`b2493b2`).
- [x] B4. `SignedImageURLCache` actor: path-keyed reuse, 1 h expiry with 5 min
  margin, batch signing endpoint with per-path fallback, URLCache sized at
  24 MB/64 MB, cleared on sign-out (batch 3).
- [x] B5. Two-tier polling: slim `entryStatusColumns` projection while
  processing (drops `raw_text` ≤ 12 KB/poll), full row once on terminal
  status; merge preserves locally known fields (batch 3, tested).
- [x] B6. Static ISO8601 formatters; `localDayString` composes from calendar
  components without a `DateFormatter` (batch 3).
- [x] B7. Preview publish interval 500 → 650 ms, matched to the client's
  streaming poll; contract test updated with rationale (`b2493b2`).
- [x] B8. Image signing overlaps transcription in `entry_processor`
  (`b2493b2`).
- [x] B9. Photo-picker loads two-at-a-time, order preserved (`fa6e795`).

### From investigation agents (accepted → done unless noted)
- [x] Camera frames delivered raw; composer downsamples off-main (was a
  50–150 ms main-thread render inside the picker callback) (`fa6e795`).
- [x] Auth: user id derived from token response/JWT — removes one RTT per
  sign-in/refresh AND the post-rotation failure window that could consume a
  rotated refresh token and force sign-out (`fa6e795`, tested).
- [x] Heatmap `DateFormatter` missing `en_US_POSIX` — silently empty heatmap
  for non-Latin-digit locales (`fa6e795`).
- [x] AudioRecorder meter timer: weak block timer + deinit invalidation
  (`fa6e795`).
- [x] AccountView loads parallelized after profile fetch (`fa6e795`).
- [x] Backend dedup: `safetyIdentifier` ×4 → `_shared/safety.ts`;
  `secretMatches` ×2 → `_shared/secrets.ts` (`b2493b2`).
- [x] `analysis_context` bounded to 6 k chars before prompt embedding
  (`b2493b2`).
- [x] Onboarding failure-write can no longer mask the original error
  (`b2493b2`).
- [x] Account-deletion storage passes parallelized (`b2493b2`).
- [x] Weekly narrative prompt states averages cover logged days only
  (`b2493b2`).
- [x] Web: dashboard fetches one 7-day window (was: selected day fetched
  twice); target history bounded to window + latest prior row; /meals day
  headers use true day totals across page boundaries; OAuth provider list
  server-rendered (kills login-card pop-in); root error boundary added;
  `bg-surface/88` (silently dropped by Tailwind) → `bg-surface/[0.88]`;
  native `<progress>` → styled div bar; Avenir auth override and unused
  `.text-balance` removed; reset CTA glow unified to accent (batch 3).
- [ ] Native UI polish batch (agent implementing; radius tokens, hairline
  unification, Reduce Motion gates, touch targets, Dynamic Type, per-render
  formatter hoisting — see UI audit list).

### Rejected / deferred (reasons)
- [-] Per-photo image inputs instead of collage: gpt-5.6 patch pricing makes
  the 1600 px collage a good cost/latency bound (~2,500 patches vs ~4×); no
  measured quality gap; schema/storage churn. Revisit only with evidence.
- [-] `detail:"original"`/`auto` on gpt-5.6: uncapped patch cost.
- [-] Local JWT verification / dispatch double-auth collapse (getUser →
  signed internal header): real latency win (~2 RTT/meal) but changes
  revocation semantics — needs owner sign-off, not an overnight call.
- [-] Claim RPCs returning the row (saves 1 DB RTT each): needs a forward
  migration + contract updates; medium win, deferred with design noted.
- [-] `entry_corrections(entry_id)` index migration: cascade delete currently
  seq-scans, negligible at single-user scale; DB agent rates it
  future-proofing only. Documented for when scale changes.
- [-] Web meal-photo thumbnails: product decision for Luke (privacy surface:
  signed URLs in server-rendered HTML; needs next/image remote patterns).
  Currently `image_path` only drives a glyph.
- [-] Web deep-link `?next=` threading through login: two-page app, touches
  proxy + form + magic-link redirect; poor risk/benefit tonight.
- [-] Composer storing JPEG `Data` instead of `UIImage`s: thumbnails need the
  images; ~30 MB transient peak acceptable; encode-ahead already implemented.
- [-] Realtime/pub-sub instead of polling: two-tier polling + backoff is
  simple and observed-cost is now low; Realtime adds a connection + auth
  lifecycle for marginal gain at this scale.
- [-] `daily_totals` covering index: 84-day window ≈ hundreds of rows; not
  worth a migration without profiling evidence (DB agent concurs).

## Operational notes (not code changes)
- The 135 s processing lease is the duplicate-provider-spend boundary: work
  exceeding the lease can be claimed again and both attempts reserve AI
  budget (data integrity protected by attempt fencing). Keep lease >
  worst-case model latency when tuning timeouts.
- `-shudoPolishPreview` launch argument drives PolishPreviewView (manual
  design QA); wired but not exercised by any test/scheme — intentional.

## Adversarial review round (post-batch)

Two independent adversarial reviewers were instructed to refute the full
`fc19b0e..HEAD` diff. Native review: no critical/major findings; backend
review found one HIGH. All accepted findings were fixed and re-verified:

- **HIGH (fixed):** the create_entry auth/form-parse overlap left the auth
  promise unhandled until the body finished parsing — a missing/invalid
  Authorization header (deterministically) or an expired token during a slow
  photo upload (racy) rejected with no handler attached and killed the whole
  Edge worker (empirically reproduced by the reviewer with a streaming
  client). Fixed by parking a no-op rejection handler at promise creation;
  the awaited original still surfaces the real 401.
- Fixed: mid-processing content regression — the slim poll froze the row
  title/raw-text at the optimistic value through the whole analyzing phase
  (server rewrites `raw_text` at status transitions). Poll now full-fetches
  on every status *transition* and uses the slim projection only for
  same-status polls (the frequent case).
- Fixed: sign-out now clears `URLCache.shared` (meal-photo bytes no longer
  persist on disk after sign-out) and `SignedImageURLCache.removeAll()`
  bumps an epoch that late stores from the previous session cannot cross
  (tested).
- Fixed: batch signing applies/caches only requested paths and falls back
  per-path for any requested path missing from a 2xx batch response (was: a
  parseable-but-partial response silently blanked all thumbnails and could
  cache unrequested paths).
- Fixed: `AudioRecorder.deinit` hops to main to invalidate the meter timer
  (deinit can run off-main; cross-thread `Timer.invalidate` violates its
  contract and could leak a permanent 60 ms wakeup).
- Fixed: `authenticate()` timeout now maps to HTTP 503 with retryable copy
  (was generic 500); login provider fetch bounded by a 3 s abort so the
  login page renders during Auth degradation; `fetchDashboardWindow` gained
  an explicit row limit and lost a dead branch; onboarding failure-write now
  also logs the common `{error}`-result path; `MAX_ANALYSIS_CONTEXT_LENGTH`
  corrected to the DB's 4,000-char constraint; stale doc comments fixed.

Accepted residual risks (documented, not fixed):
- A storage PUT that outlives its withTimeout by >5 min can orphan one
  object if the cleanup drainer processed the prefix in that exact window
  (reviewer-verified as a seconds-wide interleaving on a rare path; the
  durable cleanup queue covers every realistic timing).
- `DayFormatterCache` rebuilds on timezone change but not locale change
  mid-session (locale changes relaunch the app in practice).
- Voice-note rows keep their optimistic title during the transcribing
  phase's steady-state polls; the title now updates at the
  transcribing→analyzing transition full fetch (previously every poll).

## Follow-on feature: barcode scanning (same session, after the overnight run)

Scanning a packaged food's barcode (or a GS1 QR code) resolves nutrition from
Open Food Facts and adds a **removable card** to the composer: product name,
brand + serving size, label macros scaled live by an amount stepper
(servings, or grams for per-100 g labels). The card is a proposal — the ✕
rejects it; photos, voice, and text stay fully available alongside. On
submit the label facts serialize into the entry text after the user's own
words, and the analysis prompt now instructs the model to trust quoted label
facts and scale by the stated amount (prompt line inert until the next
Supabase deploy; the feature works without it).

Design decisions:
- Lookup database: Open Food Facts (no API key, no new secrets; barcode is
  a product ID, not personal data). Misses steer the user to photograph the
  label — the existing photo pipeline reads labels, so a miss still works.
- No live camera in Simulator → the scanner falls back to typed-code entry
  (medium-height sheet), which also covers damaged barcodes on device.
- Wire format unchanged: everything rides the existing text field, so
  quotas, idempotent retries, and corrections apply untouched. No backend
  or schema changes required for the feature itself.
- Verified in-simulator with live lookups: US serving-label product
  (Cheerios, zero-padded UPC-A), per-100 g product, miss state, card
  removal, stepper scaling (1 → 2 servings doubled macros), and
  accessibility-medium Dynamic Type.

## Morning phone QA checklist (ordered)

1. Open Shudo → Today loads; thumbnails appear without flashing placeholders.
   Pull to refresh twice — images must NOT flicker or re-download visibly.
2. Log a meal with 3–4 library photos + a voice note + a short text: the
   composer must stay responsive while photos load; **Log meal** must feel
   instant (no freeze) and the sheet dismiss promptly; the streamed preview
   sentence should appear within a few seconds of "Estimating".
3. Take a camera photo in the composer — the camera should dismiss without a
   stutter and the photo appear in the grid.
4. Submit two captures back-to-back (second while first still processing);
   both rows should progress and complete independently.
5. Open the completed meal's detail immediately — the photo should render
   quickly (cached URL) and the layout must not jump when it loads.
6. Add a correction ("the rice was one cup") — previous totals stay visible
   until the update lands; on failure the old estimate is restored.
7. Switch to yesterday and back; background the app 30 s and return — no
   visible reload churn, no stale "still working" rows.
8. Settings: sections load together; heatmap/trends scroll smoothly; theme
   switch (Studio/Carbon/Oxide) keeps hairlines/radii coherent.
9. Accessibility spot-check: enable Reduce Motion (status text should not
   typewriter), largest Dynamic Type (Today calorie number scales; meal rows
   wrap instead of clipping), VoiceOver on a meal row and the detail photo.
10. Web (after Vercel deploy): login page renders provider buttons without
    pop-in; /terms and /support cards have a visible background; day headers
    on /meals show full-day totals.

## Findings, changes, evidence

- Baselines: all suites green before changes (see table above); native suite
  re-run green after batch 1; Deno suite green after batch 2 (69 tests).
- Batch 1 (`fa6e795`): capture-path stalls removed at the source — submit tap
  no longer renders; measured-by-construction: the collage/encode work now
  happens at photo-selection time on a background queue, and the redundant
  second render (collage → `resizedForUpload` at identical size) is gone.
- Batch 2 (`b2493b2`): time-to-202 for a photo+voice capture now pays
  max(image, audio) upload instead of image+audio, and auth RTT overlaps
  body parsing. Worker time-to-analysis no longer serializes the signing RTT
  after transcription.
- Batch 3: AsyncImage flicker eliminated by stable URL identity (root cause
  confirmed independently by UI audit agent); day loads sign only uncached
  paths (usually zero) in one batch request instead of N POSTs.
