# Learning & Active Recall Specification

## Philosophy

### What It Actually Means to Learn

Learning isn't the passive consumption of information - it's the **active reconstruction of knowledge from memory**. True learning happens when you struggle to retrieve information, not when you smoothly read it again.

The brain strengthens neural pathways through **retrieval practice** - the effortful process of pulling information out of memory. Each successful retrieval makes that knowledge more durable and accessible. Failed retrievals, counterintuitively, also strengthen learning when followed by feedback.

### The Illusion of Knowing

Most "studying" creates an **illusion of competence**:
- Re-reading feels productive but builds weak memory traces
- Highlighting creates familiarity, not recall ability
- Passive review produces recognition, not retrieval strength

The test: Can you produce the answer from a blank slate? Not "does this look familiar when I see it?"

### Active Recall: The Core Mechanism

**Active recall** forces the brain to reconstruct knowledge without cues. It's uncomfortable precisely because it works - the struggle of retrieval is the signal that learning is occurring.

Key principles:
1. **Generation effect**: Producing an answer creates stronger memory than reading it
2. **Desirable difficulty**: Harder retrieval (within limits) = stronger encoding
3. **Testing effect**: Being tested improves retention more than additional study
4. **Elaborative interrogation**: Asking "why?" and "how?" deepens understanding

### Spaced Repetition: Optimizing the Forgetting Curve

Hermann Ebbinghaus discovered that memory decays exponentially - the **forgetting curve**. But each review resets and flattens the curve. The insight: time your reviews to catch knowledge just before it fades.

**Spacing effect**: Distributed practice beats massed practice. Studying 1 hour across 4 days beats 4 hours in one session. The brain needs time to consolidate.

**Optimal intervals** expand over time:
- First review: 1 day
- Second review: 3 days
- Third review: 7 days
- Fourth review: 14 days
- Fifth review: 30 days
- ... (exponential growth)

The magic: Eventually, you're reviewing yearly for knowledge that lasts a lifetime.

---

## System Design for Shudo Learning

### Core Concept: Ghost-Like Minimalism

The app should be **invisible until needed**. Like a ghost that occasionally materializes:
- No dashboard to obsessively check
- No streaks that create anxiety
- No gamification that corrupts intrinsic motivation
- Just: **random, gentle prompts throughout the day**

### The User Journey

1. **Capture**: User encounters an interesting fact/concept → adds it in seconds
2. **Forget**: User goes about their life, doesn't think about the app
3. **Interrupt**: At random moments, a gentle notification asks a question
4. **Retrieve**: User actively recalls the answer (or fails and learns)
5. **Repeat**: The system schedules the next review based on performance

### Data Model

```typescript
interface LearningItem {
  id: string
  user_id: string
  created_at: timestamp

  // The knowledge to learn
  concept: string          // The question/prompt shown during review
  answer: string           // The correct response (revealed after attempt)
  context?: string         // Optional: source, why it matters, related ideas
  tags?: string[]          // Optional: categorization

  // Spaced repetition state
  ease_factor: number      // Multiplier for interval (starts at 2.5, adjusted by performance)
  interval_days: number    // Current spacing between reviews
  next_review_at: timestamp
  review_count: number     // Total times reviewed

  // Performance history
  last_review_at?: timestamp
  last_quality: number     // 0-5 scale: 0=blackout, 3=correct with effort, 5=instant
  consecutive_correct: number
  consecutive_wrong: number

  // Lifecycle
  status: 'new' | 'learning' | 'review' | 'suspended' | 'buried'
}

interface ReviewSession {
  id: string
  user_id: string
  item_id: string
  reviewed_at: timestamp
  quality: number          // User self-rating 0-5
  response_time_ms: number // How long they took to respond
  was_correct: boolean     // Did they get it right?
}
```

### The SM-2 Algorithm (Simplified)

After each review, update the item based on quality (0-5):

```typescript
function updateSpacedRepetition(item: LearningItem, quality: number): LearningItem {
  // Quality scale:
  // 5 - Perfect response, instant recall
  // 4 - Correct after brief hesitation
  // 3 - Correct with significant difficulty
  // 2 - Incorrect, but recognized correct answer
  // 1 - Incorrect, vaguely remembered
  // 0 - Complete blackout

  if (quality < 3) {
    // Failed - reset to learning phase
    return {
      ...item,
      consecutive_correct: 0,
      consecutive_wrong: item.consecutive_wrong + 1,
      interval_days: 1,  // Review again tomorrow
      next_review_at: addDays(now(), 1),
      status: 'learning'
    }
  }

  // Passed - extend interval
  const newEase = Math.max(1.3,
    item.ease_factor + (0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02))
  )

  let newInterval: number
  if (item.interval_days === 0) {
    newInterval = 1
  } else if (item.interval_days === 1) {
    newInterval = 6
  } else {
    newInterval = Math.round(item.interval_days * newEase)
  }

  return {
    ...item,
    ease_factor: newEase,
    interval_days: newInterval,
    next_review_at: addDays(now(), newInterval),
    consecutive_correct: item.consecutive_correct + 1,
    consecutive_wrong: 0,
    review_count: item.review_count + 1,
    status: 'review'
  }
}
```

### Notification Strategy

**The goal**: Catch users in interstitial moments, not interrupt deep work.

Triggers:
- User unlocks device → small chance of prompt
- User switches apps → small chance of prompt
- Scheduled random times during waking hours
- Never during Do Not Disturb or Focus modes

Frequency caps:
- Max 5-10 reviews per day (configurable)
- Minimum 1 hour between notifications
- Skip if user dismissed last 3 in a row (they're busy)

Notification format:
```
[Shudo] Quick recall:
"What is the spacing effect?"
Tap to answer →
```

### Input Methods for Adding Items

**Text** (primary):
- Front: "What is..." / Back: "The answer is..."
- Single field that auto-splits on common patterns

**Voice**:
- "Add to learn: [concept]. The answer is [answer]."
- AI parses into front/back

**Screenshot OCR**:
- Select text from any app
- AI suggests question/answer split

**Quick capture**:
- Paste any text → AI generates flashcard suggestions
- User approves/edits before saving

### Review Interface

Minimal, focused, fast:

```
┌─────────────────────────────────┐
│                                 │
│   What is the spacing effect?   │
│                                 │
│         [Show Answer]           │
│                                 │
└─────────────────────────────────┘

(after tap)

┌─────────────────────────────────┐
│                                 │
│   What is the spacing effect?   │
│                                 │
│   Distributing practice over    │
│   time improves retention       │
│   compared to massed practice   │
│                                 │
│   How did you do?               │
│                                 │
│   [Hard]  [Good]  [Easy]        │
│      1d     6d      14d         │
│                                 │
└─────────────────────────────────┘
```

Three buttons only:
- **Hard** (quality 2-3): Got it with struggle or partial recall
- **Good** (quality 4): Normal successful recall
- **Easy** (quality 5): Instant, effortless

No "Again" button in the UI - failures are detected by "Hard" or dismissal.

---

## Anti-Patterns to Avoid

### Don't Build
- Leaderboards or social features (corrupts intrinsic motivation)
- Streaks with penalties (creates anxiety, not learning)
- Complex statistics dashboards (distraction from actual review)
- Achievements or badges (gamification doesn't improve retention)
- Card customization/themes (feature creep)

### Do Build
- Frictionless capture (seconds, not minutes)
- Invisible scheduling (the algorithm handles it)
- Gentle interruptions (respect user attention)
- Simple review (3 buttons max)
- Progress through consistency, not metrics

---

## Success Metrics (Internal Only)

Measure learning, not engagement:
- **Retention rate**: % of items successfully recalled after 30/60/90 days
- **Ease factor trends**: Are items getting easier over time?
- **Time to stability**: How many reviews until an item reaches 30+ day intervals?
- **Capture-to-first-review**: How many items are never reviewed?

Not measured:
- Daily active users (vanity metric)
- Time in app (less is better)
- Cards created per day (quality > quantity)

---

## Implementation Phases

### Phase 1: Core Loop
- [ ] Data model for learning items
- [ ] SM-2 algorithm implementation
- [ ] Basic text input for adding items
- [ ] Simple review interface
- [ ] Background notification scheduling

### Phase 2: Capture Methods
- [ ] Voice input with AI parsing
- [ ] Screenshot/image OCR
- [ ] Quick paste with AI suggestions

### Phase 3: Polish
- [ ] Smart notification timing
- [ ] Review session batching
- [ ] Item editing and organization
- [ ] Export/backup

### Phase 4: Insights (Optional)
- [ ] Personal retention statistics
- [ ] Difficult items identification
- [ ] Learning velocity over time

---

## References

- Ebbinghaus, H. (1885). Memory: A Contribution to Experimental Psychology
- Karpicke, J.D. & Roediger, H.L. (2008). The Critical Importance of Retrieval for Learning
- Pimsleur, P. (1967). A Memory Schedule
- Wozniak, P. & Gorzelanczyk, E.J. (1994). Optimization of Repetition Spacing (SuperMemo)
- Bjork, R.A. (1994). Memory and Metamemory Considerations in the Training of Human Beings
