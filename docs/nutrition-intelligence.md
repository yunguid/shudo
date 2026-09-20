# Nutrition intelligence pass — 2026-09-20

## Findings and changes

- Meal JSON validated individual numbers but accepted totals that disagreed with
  components. The parser now derives totals from validated items. Label calories
  remain independent of 4/4/9 arithmetic; overflow is rejected. Existing stored
  meals are not recalculated or rewritten.
- Estimation instructions now prioritize measured amounts and labels, distinguish
  food mass from protein, scale per-serving and per-100g values, preserve raw,
  cooked and drained states, and make newest corrections authoritative. Material
  ambiguity produces a provisional assumption and one useful question in notes.
- Barcode matches are identified as Open Food Facts data, not a directly scanned
  or independently verified package label. The capture card asks the user to
  compare the match with their package, and already-scaled totals are identified.
- Existing targeted web search remains bounded to two calls. Ordinary meals and
  supplied barcode labels retain the tool-free path. Lookup instructions prefer
  USDA for generic foods and first-party product/restaurant facts, exclude health
  history and personal context from queries, and treat retrieved text as data.
  A required lookup with no observed tool call is disclosed as unavailable.
  Source links prove consultation, not an exact product or portion match.
- Notifications use the editable profile display name. Empty days receive one
  logging reminder, never a guessed deficit; other days have at most two meal
  checkpoints plus the existing opted-in weigh-in reminder. Protein copy reports
  the last logged snapshot and own target. Recent dinner suppresses closeout.
  Removed speculative food coaching and its now-unused food-selection helpers.
  Checkpoint creation respects daylight-saving changes and the profile timezone.
- Weekly insights show all seven protein days with their historical targets,
  unknown days distinct from logged zero, and today's remaining amount. Averages
  explicitly cover logged days and may include incomplete days. Concurrent loads
  commit together, so an error cannot display a mixed snapshot as fresh data.
  Week navigation has 44-point targets and keeps its existing selection haptic.
- The editable name path already exists in onboarding/profile settings; no name
  is hardcoded and no profile or production meal data is changed by this pass.
- Dependency audit found 15 web vulnerabilities. Updated Next.js and its ESLint
  config to 16.3.5, PostCSS to 8.5.28, Sharp to 0.35.4, the existing compatibility
  facade's upstream brace-expansion to 5.0.12, and affected lockfile dependencies.
  Kept the intentionally full navigation after password login with a narrow
  explanation for the new Next.js lint rule.

## OpenAI audit and model decision

Retained `gpt-5.6-sol` for meal, onboarding, weekly narrative and micronutrient
calls, and `gpt-4o-transcribe` for audio. Official model documentation confirms
Sol supports image input, streaming, structured outputs, web search, and low
reasoning. Existing `store: false`, strict schemas, timeouts, quotas, durable
claims, correction rollback and bounded output budgets remain intact. No model
migration is justified without representative quality/latency measurements.

Onboarding uses stated facts with deterministic target computation and editable
results. Weekly narratives receive computed metrics and distinguish unlogged
calendar days. Micronutrient calls have no retrieval tools; their prompt now
explicitly forbids claiming database or label verification and lowers confidence
for unknown fortification or recipes. This pass does not make those estimates
laboratory measurements or individualized micronutrient requirements.

Official documentation checked:

- https://developers.openai.com/api/docs/models/gpt-5.6-sol
- https://developers.openai.com/api/docs/models/gpt-4o-transcribe
- https://developers.openai.com/api/docs/guides/structured-outputs
- https://developers.openai.com/api/docs/guides/tools-web-search

## Portion reference decision

Added a small in-app reference reachable from weekly insights. Bars compare
cooked food weight with protein content; they are explicitly not life-size or
pictures of the protein within a food. A palm comparison is an approximation,
not a measurement. Product labels and a scale remain the better evidence.

Sources checked September 20, 2026:

- Allina Health: cooked chicken breast, 3 oz, 26g protein:
  https://www.allinahealth.org/health-conditions-and-treatments/eat-healthy/nutrition-basics/protein/meat-poultry-and-fish
- USDA SR Legacy (2018), protein table: roasted turkey breast meat only,
  3 oz, 25.61g; wild coho salmon cooked with moist heat, 3 oz, 23.26g:
  https://www.nal.usda.gov/sites/default/files/page-files/Protein.pdf
- Johns Hopkins portion guide, palm-sized meat portion heuristic:
  https://www.hopkinsmedicine.org/-/media/migration/all-childrens-hospital/documents/services/healthy-weight-initiative/goslowwhoafoodlistspdf.pdf

Three ounces is 85.0485g of food; the UI rounds this to 85g. MyPlate food-group
ounce-equivalents must not be treated as ounces of pure protein. No stock or
generated food photograph is presented as evidence of a precise portion.

## Evaluation boundary

`scripts/eval-nutrition.ts` runs nine synthetic cases directly through the meal
processor: label scaling, per-100g scaling, powder versus protein weight, ounces,
cooked/dry rice, conflicting corrections, ambiguity, and a targeted USDA lookup.
It never reads or writes Supabase data and prints no key or personal content.
Run with an authorized `OPENAI_API_KEY` in the environment:

```
deno run --allow-env --allow-net=api.openai.com scripts/eval-nutrition.ts
```

The local credential returned HTTP 401 on this pass. No live model-quality or
accuracy improvement is claimed. The hosted credential is separate and was not
changed. Photo estimation has not received a live-image eval in this pass.
Deterministic tests cover arithmetic, overflow, lookup provenance, historical
protein targets, missing versus zero logs, name fallback and reminder behavior.
Offline UI fixtures exercise opening the reference and scrolling to history.
