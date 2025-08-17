## Next steps (product + implementation checklist)

- [ ] Sign‑up and onboarding personalization
  - [ ] Multi‑step `OnboardingFlowView` after account creation
    - [ ] Collect height, weight, target weight, exercise level (sedentary → extra active)
    - [ ] Optional cutoff time to stop eating (default 8:00 PM)
    - [ ] Unit toggles (lb/kg, ft+in/cm), validation, accessibility
  - [ ] Persist to `profiles`
    - [ ] Add columns: `height_cm` NUMERIC, `weight_kg` NUMERIC, `target_weight_kg` NUMERIC, `activity_level` TEXT, `cutoff_time_local` TIME, `updated_at` TIMESTAMPTZ
    - [ ] RLS: user can read/update only own row
  - [ ] Compute daily target calories + macros
    - [ ] `CalorieEstimator` service: base × activity multiplier
    - [ ] Defaults: protein ~1.8 g/kg target, fat ~0.8 g/kg target, carbs = remaining kcal/4 (with clamps)
    - [ ] Save into `profiles.daily_macro_target`; refresh UI
  - [ ] Countdown UI in header/toolbar
    - [ ] Show “Stop in hh:mm” until cutoff; after cutoff show “Over by hh:mm” in red
    - [ ] Drive with `Timer.publish(every: 30, on: .main, in: .common).autoconnect()`
    - [ ] Use `profile.timezone` + `cutoff_time_local` (fallback 20:00)

- [ ] Email sign‑up confirmation UX (friendly, non‑technical)
  - [ ] Do not auto‑sign‑in immediately after `signUp(email,password)` when email confirmation is enabled
  - [ ] Map Supabase responses/errors to a friendly state: show a modal/card “Please check your email to confirm your account. After confirmation, return to the app.”
  - [ ] Provide a “Resend confirmation” action (rate‑limited)
  - [ ] Optional: configure redirect/deeplink (e.g., `shudo://auth-callback`) and handle in app to auto‑resume session
  - [ ] Analytics breadcrumb for confirmation sent → confirmed

- [ ] Edit/delete entries
  - [ ] Swipe actions on `EntryCard`
    - [ ] Delete → `DELETE /rest/v1/entries?id=eq.{uuid}`; if `image_path` exists, delete from Storage bucket
    - [ ] Edit → open `EntryComposerView` prefilled; `PATCH /rest/v1/entries?id=eq.{uuid}`
  - [ ] `TodayViewModel`
    - [ ] `deleteEntry(_:)` with optimistic remove + totals recompute
    - [ ] `updateEntry(_:)` with optimistic update + totals recompute
  - [ ] RLS policies: allow owner to `update`/`delete` own rows; Storage policy to delete own `entry-images/*`

- [ ] Global cutoff countdown (if no personalized cutoff yet)
  - [ ] Compute time to next local 20:00 in `profile.timezone`
  - [ ] Display neutral before cutoff; red after cutoff; keep DST‑safe

- [ ] Database migrations and hygiene
  - [ ] SQL migrations
    - [ ] `003_profiles_personalization.sql`: add columns listed above (with sensible defaults where possible)
    - [ ] `004_policies_entries_update_delete.sql`: RLS to allow owner UPDATE/DELETE on `entries`
  - [ ] Indexes: `profiles(user_id)`, `entries(user_id, created_at desc)`
  - [ ] Ensure Storage bucket `entry-images` exists; policies align with `user_id`
  - [ ] Backfill existing profiles with default targets and cutoff time

- [ ] Color system plan (refine visual identity)
  - [ ] Define semantic tokens in `Design.Color` (keep dynamic system integration):
    - [ ] `ink`, `paper`, `fill`, `rule` (hairline)
    - [ ] `accentPrimary`, `accentSecondary`
    - [ ] `success`, `warning`, `danger`
    - [ ] `ringProtein`, `ringCarb`, `ringFat` (or derive from a single accent hue)
  - [ ] Add Color Assets for light/dark variants; keep WCAG AA for text on surfaces
  - [ ] Wire `.tint(Design.Color.accentPrimary)` globally; update rings to use semantic tokens
  - [ ] Document usage: numbers remain high‑contrast; badges subdued; overflow in `danger`
  - [ ] Snapshot pass in light/dark, increase/decrease contrast settings

- [ ] QA/UX polish
  - [ ] Header countdown aligns with timezone label and updates live
  - [ ] Macro dials and calorie gauge react instantly to edits/deletes
  - [ ] Friendly error messages and retry for network failures
  - [ ] Dark mode snapshot pass

- [ ] DevOps & version control
  - [ ] Commit sequence: migrations → service changes → UI (feature flags where helpful)
  - [ ] Add rollback notes for each migration
  - [ ] Lightweight smoke script for REST endpoints (create/edit/delete entry, profile update)

## Notes

- The current front‑end refresh compiles and runs; networking/models were preserved.
- The email confirmation UX change requires altering `SupabaseAuthService.signUp` to stop auto‑sign‑in on success and surface a friendly “Check your email” state instead of raw errors.
- Color plan favors a restrained palette; accents should be configurable to a brand hue without harming contrast.


