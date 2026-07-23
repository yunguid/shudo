# Shudo overnight audit — 2026-07-23

Autonomous overnight performance, quality, and visual refinement run per `spec.md`.
Working directly on `main`; each batch is committed after focused verification.

## Baseline (recorded before any change)

| Check | Result | Notes |
| --- | --- | --- |
| Deno `fmt --check`, `lint`, `check` (all functions) | PASS | |
| Deno function tests (`deno test`) | PASS | |
| Native unit tests (`xcodebuild test`, iPhone 17 Pro sim, warnings-as-errors) | PASS | ~14 s test phase |
| Web tests/lint/typecheck/build | see below | run during investigation |
| Worktree | clean at `fc19b0e`, synced with `origin/main` | |

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
- [ ] B1. Move collage/JPEG preparation off the submit tap: pre-encode upload
  JPEG in background as photos change; submit uses prepared `Data`.
- [ ] B2. Kill the redundant second full-size render (`jpegData` →
  `resizedForUpload` on an already-sized collage); share one `CIContext`.
- [ ] B3. Parallelize image+audio Storage uploads in `create_entry`; overlap
  `authenticate()` with `req.formData()`.
- [ ] B4. Stable signed-URL cache keyed by storage path (batch sign endpoint,
  longer expiry, in-memory reuse across list/poll/detail) → stops AsyncImage
  flicker + re-downloads; drop per-poll/detail duplicate signing.
- [ ] B5. Slim polling projection (drop `raw_text` etc. while processing) with
  full fetch on completion; preserve optimistic summary during merge.
- [ ] B6. Cache ISO8601/day formatters (created per parse/per call today).
- [ ] B7. Preview publish interval 500 ms → align with client's 650 ms poll
  (cut unobserved writes) — keep first-preview-immediate behavior.
- [ ] B8. Overlap image signing with transcription in `entry_processor`
  (sign is independent of transcript).
- [ ] B9. Bounded-concurrency photo loading in composer (order-preserving),
  replacing serial `loadTransferable` loop.

### P2 — pending investigation reports
- [ ] UI audit findings (agent).
- [ ] Backend audit findings (agent).
- [ ] DB/migrations audit findings (agent).
- [ ] Web audit + baseline (agent).
- [ ] Native services audit (agent, incl. CameraPicker full-res retention,
  AudioRecorder settings).

## Findings, changes, evidence

(appended per batch below)
