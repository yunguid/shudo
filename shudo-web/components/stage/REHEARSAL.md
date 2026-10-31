# Rehearsal: today-demo

The Shudo Today screen on an iPhone, beside the sign-in card on
`/auth/login` (shown from the `lg` breakpoint; below it the card stands
alone, as before). Built with the stageshow kit vendored at
`components/stage/kit` (brand marks left out).

Gold: `messages` (a phone cropped at the top, composer and bottom edge in
view, a typed reply forming into a bubble) with `phone-touch`'s touch
cursor. Kept: the crop and gutter, play once, the bubble forming out of the
field, the poster as the finished conversation. Changed: the product is
Shudo's own Today screen drawn at its points (DayHeader figure and strokes,
walnut and heartwood bubbles, the ThreadCard, the meal receipt, the resting
field, the command band with the key and tab bar) in Merriweather; the
thread is `imessage` with the tails hidden and Shudo's colors and radii; the
figure rolls with the receipt.

Beats: 1 context (the lift's receipt, the PR, dinner talk) · 2 the field is
tapped, dinner typed, sent; the receipt lands working · 3 the receipt
settles, 1,120 → 425 kcal left, 121 → 179 g protein, strokes grow · 4 Shudo
types, then answers; the conversation holds. About 13 s, `play="once"`.

Captured (film.mjs from the skill's repo, Chrome, dev server):
- wide loop, 1280: `wide3.png`; states sheet: `states.png`
- compact, 390 (a temporary `/auth/demo` page, removed): `compact2.png`
- the send beat at 50 ms: `send-beat.png`; reduced motion still: `reduced.png`

Film lines and what was done:
- `translucent icon` (tab glyph fillOpacity) → opaque fill.
- `loose stack` (PR card eyebrow 13px above its line) → 5px gap.
- `touching` (macro counters) → carbs and fat on a `Roll`, 4px gaps.
- `jump` (“kcal left” x −21px at settle: `Count` reserves no width when the
  figure loses a digit) → the figure is a `Roll`, which eases the width.
- `lands on a transform` (receipt number) → `will-change: transform`.
- compact `framing` (phone 10px short of the bottom) → stage 600 tall, 16px
  gutter; compact `small text` (8.7px) → `--sh-small`/`--sh-meta` step up
  to 13.5px in compact.
- `kit override: .ss-phone__screen/status/island/home` ×6: stands. The
  flagged selectors are the kit's own rules; the detector skips sheets whose
  URL contains `/kit/`, and Next bundles the kit's CSS into one chunk, so it
  attributes them to the demo. No rule in `today-demo.css` targets them.
- `settle snap` (a `Count` strip moving with no transition): the kit's own
  strip recentering after a roll, unseen; stands.
- `manual: same-box content change` on the field while typing: the typed
  text with a caret; inspected on the send sheet.
- Coverage is `inconclusive` on the dev server (sampling gaps over 27 ms);
  the gate's never-intentional count is 6, all the kit-override lines above.

Not checked: the loop on a real iPhone or iPad (touch is emulated); the
page under Safari; the motion at the host's `lg` breakpoint (1024–1279),
where the copy stacks above the phone and the page scrolls; Windows fonts
for Merriweather fallbacks.

Assumptions: the sign-in card is the task, so the demo only appears from
`lg`; the brief named no size, and 400 × 644 was chosen so copy, phone
and card fit a laptop viewport at `xl`.
