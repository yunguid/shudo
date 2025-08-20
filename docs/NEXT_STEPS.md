## Next steps (product + implementation checklist)

- [x] Meal detail page showing raw AI output (read‑only)
  - [x] Tap an `EntryCard` to push `EntryDetailView` with key/value inspector
  - [x] Include photo and notes when available

- [x] Day navigation fixes
  - [x] Disable future button when on today
  - [x] Prevent navigating into future dates via code

- [x] Mic icon tint stability in composer
  - [x] Force app accent color on mic/stop icon, avoid default blue

- [x] Macro target computation tuned for bulking
  - [x] Protein 1.8 g per lb of target weight; Fat ~0.4 g/lb; Carbs remainder; ~10% kcal surplus

- [x] Basic Account page (email + profile fields)

- [x] Email flows
  - [x] If email already registered, surface friendly error and suggest sign‑in
  - [x] Sign‑up screen: disable “Sign Up” when authenticated
  - [x] Post‑confirmation landing: friendly page (no localhost error) when not deep‑linking
  - [x] Friendlier error for non‑existent or unconfirmed accounts (no raw JSON)
