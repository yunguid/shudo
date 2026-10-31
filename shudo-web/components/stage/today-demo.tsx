'use client'

import { ArrowUp, ChevronDown, MessagesSquare, PersonStanding } from 'lucide-react'
import { Merriweather } from 'next/font/google'
import { Bubble, Count, Phone, Roll, Stage, Stamp, Thread, type Act } from './kit'
import './today-demo.css'

// Shudo's Today screen on an iPhone, for the sign-in page. Gold: `messages`
// (a phone cropped at the top, its composer and bottom edge in view) with
// `phone-touch`'s touch cursor. Four beats:
//   1. Context: the day's figure over its two strokes, the coach's last two
//      texts after the evening lift, the resting "Message Shudo…" field.
//   2. Action: the field is tapped and dinner is typed; send lifts the words
//      into a heartwood bubble, and the receipt lands under it, working.
//   3. Result: the receipt settles (macros and 695 kcal) and the figure
//      rolls: kcal left down, protein up, the strokes grow.
//   4. Payoff: Shudo types, then answers. The conversation holds; the poster
//      is this last frame.
//
// Real strings: the figure and its macros, the stamp, the coach's two texts,
// the typed dinner, the receipt, the reply, the field's prompt, the tabs.
// Everything is drawn at the app's own points inside the kit's Phone and
// cropped above the figure, so the title row and status bar are true chrome
// under the cut.

const merriweather = Merriweather({
  subsets: ['latin'],
  weight: ['300', '400', '500', '600'],
  variable: '--font-merriweather',
  display: 'swap',
})

type Receipt = 'none' | 'working' | 'done'

type S = {
  draft: string
  focus: boolean
  sent: boolean
  receipt: Receipt
  typing: boolean
  reply: boolean
  kcal: number
  protein: number
  carbs: number
  fat: number
}

const TARGET_KCAL = 2650
const TARGET_PROTEIN = 175

const START: S = {
  draft: '',
  focus: false,
  sent: false,
  receipt: 'none',
  typing: false,
  reply: false,
  kcal: 1120,
  protein: 121,
  carbs: 185,
  fat: 44,
}

const END: S = {
  ...START,
  sent: true,
  receipt: 'done',
  reply: true,
  kcal: 425,
  protein: 179,
  carbs: 257,
  fat: 63,
}

const DINNER = 'Steak, two cups of rice, broccoli'
const REPLY = 'Protein’s done. 425 left — a glass of milk and you’re there.'

async function script(a: Act<S>) {
  await a.wait(900)
  a.mark('type')
  await a.click('compose')
  await a.set({ focus: true })
  await a.type('draft', DINNER, { interval: 48 })
  await a.wait(380)
  a.mark('send')
  await a.click({ at: 'send', x: 0.5, y: 0.5 })
  // Clear the field in the same update that adds the bubble: the words lift out of it
  await a.set({ sent: true, draft: '', focus: false })
  // The finger lifts away over the thread; the touch style shows nothing between taps
  a.move({ x: 200, y: 420 })
  await a.wait(650)
  await a.set({ receipt: 'working' })
  await a.wait(2100)
  a.mark('settle')
  await a.set({ receipt: 'done', kcal: END.kcal, protein: END.protein, carbs: END.carbs, fat: END.fat })
  await a.wait(1200)
  await a.set({ typing: true })
  await a.wait(1700)
  a.mark('reply')
  await a.set({ typing: false, reply: true })
  await a.wait(3200)
  a.mark('done')
}

/** Train's own mark, the three rising steps from ShellTabBar.swift. */
function TrainSteps({ filled }: { filled: boolean }) {
  // The Swift path on an 18×16 frame, inset by half the 1.8 stroke
  const x0 = 0.9
  const y0 = 0.9
  const w = 18 - 1.8
  const h = 16 - 1.8
  const run = w / 3
  const rise = h / 3
  let d = `M${x0} ${y0 + h}`
  for (let step = 0; step < 3; step++) {
    const x = x0 + step * run
    const y = y0 + h - (step + 1) * rise
    d += ` L${x} ${y} L${x + run} ${y}`
  }
  d += ` L${x0 + w} ${y0 + h} Z`
  return (
    <svg viewBox="0 0 18 16" width="18" height="16" aria-hidden>
      <path d={d} fill={filled ? 'currentColor' : 'none'} stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" />
    </svg>
  )
}

/** The pad-grid mark on the command key: CoachAvatar without its disc. */
function PadGrid() {
  return (
    <span className="sh-pads" aria-hidden>
      {Array.from({ length: 9 }, (_, i) => (
        <i key={i} data-row={Math.floor(i / 3)} />
      ))}
    </span>
  )
}

export function TodayDemo() {
  return (
    <div className={`sh-demo ${merriweather.variable}`}>
      <Stage<S>
        width={400}
        height={644}
        compact={{ below: 398, width: 358, height: 600 }}
        theme="dark"
        fidelity="realistic"
        initial={START}
        poster={END}
        script={script}
        play="once"
        cursor={{ at: 'compose', style: 'touch' }}
        tokens={{
          '--ss-font': 'var(--font-merriweather), Georgia, serif',
          '--ss-accent': '#d26842',
          '--ss-accent-soft': 'rgba(210, 104, 66, 0.18)',
          '--ss-canvas': '#0e0b09',
          '--ss-surface': '#17120f',
          '--ss-raised': '#211a16',
          '--ss-text-strong': '#f1e7d8',
          '--ss-text': '#b8a891',
          '--ss-text-faint': '#978770',
          '--ss-icon': '#b8a891',
          '--ss-line': 'rgba(241, 231, 216, 0.08)',
          '--ss-line-faint': 'rgba(241, 231, 216, 0.05)',
          '--ss-radius-md': '14px',
          '--ss-radius-lg': '20px',
        }}
      >
        {(s, _rect, layout) => {
          const kcalProgress = Math.min(1, Math.max(0, (TARGET_KCAL - s.kcal) / TARGET_KCAL))
          const proteinProgress = Math.min(1, s.protein / TARGET_PROTEIN)
          return (
            <Phone width={layout === 'compact' ? 326 : 350} frame="pro" dark wallpaper="#0e0b09" time="7:24" className="sh-phone">
              <div className="sh-app">
                {/* The day's header, as DayHeader draws it: the title row sits under the crop; the figure is the first thing in view */}
                <header className="sh-head">
                  <div className="sh-title-row">
                    <span className="sh-title">
                      <span className="sh-title__day">
                        Today
                        <ChevronDown size={11} strokeWidth={2.4} aria-hidden />
                      </span>
                      <span className="sh-title__sub">Day 35 of the bulk</span>
                    </span>
                    <span className="sh-seal">L</span>
                  </div>
                  <div className="sh-figure">
                    <span className="sh-remaining">
                      <span className="sh-remaining__n">
                        {/* Roll, not Count: the figure drops a digit and its comma, and Roll eases the width so "kcal left" glides with it */}
                        <Roll>{s.kcal.toLocaleString('en-US')}</Roll>
                      </span>
                      <span className="sh-remaining__label">kcal left</span>
                    </span>
                    <span className="sh-macros">
                      <span className="sh-macros__protein">
                        <b>
                          <Count value={s.protein} />
                        </b>
                        <span>g protein</span>
                      </span>
                      <span className="sh-macros__rest">
                        <Roll>{`${s.carbs} C  ·  ${s.fat} F`}</Roll>
                      </span>
                    </span>
                  </div>
                  <div className="sh-strokes">
                    <span className="sh-stroke" data-tone="kcal">
                      <i style={{ width: `${kcalProgress * 100}%` }} />
                    </span>
                    <span className="sh-stroke" data-tone="protein">
                      <i style={{ width: `${proteinProgress * 100}%` }} />
                    </span>
                  </div>
                </header>

                <Thread className="sh-thread">
                  {/* The evening so far, as the app shows it: the lift's receipt, then Shudo on the PR, then dinner talk */}
                  <div className="sh-receipt-row" data-opening>
                    <div className="sh-receipt" data-state="done" data-kind="workout">
                      <span className="sh-receipt__text">
                        <span className="sh-receipt__title">Upper A</span>
                        <span className="sh-receipt__sub">Bench press 175×8 · +3 lifts</span>
                      </span>
                      <span className="sh-receipt__number">
                        <span className="sh-receipt__kcal">58</span>
                        <span className="sh-receipt__unit">min</span>
                      </span>
                    </div>
                  </div>
                  <Stamp className="sh-stamp">7:21 pm</Stamp>
                  <Bubble from="them">Incline PR. 70s for ten — that’s new territory.</Bubble>
                  <div className="sh-card-row">
                    <div className="sh-card">
                      <span className="sh-card__eyebrow">New PR</span>
                      <span className="sh-card__line">
                        <span>Incline DB press</span>
                        <span className="sh-card__value">
                          70 lb <b>+5</b>
                        </span>
                      </span>
                    </div>
                  </div>
                  <Bubble from="me">dinner is steak and rice. anything else?</Bubble>
                  <Bubble from="them">1,120 left and the lift earned every one. Steak, two cups of rice, and a glass of milk closes the day.</Bubble>
                  {s.sent && (
                    <Bubble from="me" source="draft">
                      {DINNER}
                    </Bubble>
                  )}
                  {s.receipt !== 'none' && (
                    <div className="sh-receipt-row">
                      <div className="sh-receipt" data-state={s.receipt}>
                        <span className="sh-receipt__text">
                          <span className="sh-receipt__title">{DINNER}</span>
                          <span className="sh-receipt__detail">
                            <span className="sh-receipt__working" aria-hidden />
                            <span className="sh-receipt__macros">
                              <span>
                                58<b data-m="p">P</b>
                              </span>
                              <span>
                                72<b data-m="c">C</b>
                              </span>
                              <span>
                                19<b data-m="f">F</b>
                              </span>
                            </span>
                          </span>
                        </span>
                        <span className="sh-receipt__number">
                          <span className="sh-receipt__kcal">695</span>
                          <span className="sh-receipt__unit">kcal</span>
                        </span>
                      </div>
                    </div>
                  )}
                  {(s.typing || s.reply) && (
                    <Bubble from="them" typing={s.typing}>
                      {REPLY}
                    </Bubble>
                  )}
                </Thread>

                {/* The resting message field, CaptureComposer at rest */}
                <div className="sh-compose" data-target="compose" data-focus={s.focus || undefined}>
                  <span className="sh-compose__text" data-target="draft">
                    {s.draft}
                    {s.focus && <i className="sh-caret" data-snap />}
                  </span>
                  {!s.draft && <span className="sh-compose__ph">Message Shudo…</span>}
                  <span className="sh-send" data-target="send" data-show={s.draft ? '' : undefined}>
                    <ArrowUp size={16} strokeWidth={2.6} aria-hidden />
                  </span>
                </div>

                {/* The command band: the well and key bottom-left, the tab bar beside it */}
                <div className="sh-band">
                  <span className="sh-well">
                    <span className="sh-key">
                      <PadGrid />
                    </span>
                  </span>
                  <nav className="sh-tabs" aria-hidden>
                    <span className="sh-tab" data-on>
                      <MessagesSquare size={17} strokeWidth={1.8} fill="currentColor" />
                      <span>Today</span>
                    </span>
                    <span className="sh-tab">
                      <PersonStanding size={18} strokeWidth={1.8} />
                      <span>Body</span>
                    </span>
                    <span className="sh-tab">
                      <TrainSteps filled={false} />
                      <span>Train</span>
                    </span>
                  </nav>
                </div>
              </div>
            </Phone>
          )
        }}
      </Stage>
    </div>
  )
}
