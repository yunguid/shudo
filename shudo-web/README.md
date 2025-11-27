# Shudo Web Analytics

A companion web dashboard for the Shudo iOS app, providing deep analytics and visualization of nutrition habits over time.

## Features

- **Dashboard** - At-a-glance view with streak counter, weekly comparisons, and trend sparklines
- **Trends** - Stacked area charts, calorie heatmaps, and goal achievement tracking
- **Meals Log** - Searchable, paginated table of all logged meals
- **Insights** - Meal timing analysis, weekday vs weekend patterns, and consistency scoring

## Tech Stack

- **Framework**: Next.js 14 (App Router)
- **Auth**: Supabase Auth (same as iOS app)
- **Styling**: Tailwind CSS
- **Charts**: Recharts
- **Database**: Supabase (shared with iOS)

## Getting Started

### Prerequisites

- Node.js 18+
- npm or yarn
- A Supabase project (shared with Shudo iOS app)

### Installation

```bash
cd shudo-web
npm install
```

### Environment Variables

Create a `.env.local` file (already included) with your Supabase credentials:

```
NEXT_PUBLIC_SUPABASE_URL=your-supabase-url
NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key
```

### Development

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000) in your browser.

### Production Build

```bash
npm run build
npm start
```

## Project Structure

```
shudo-web/
├── app/
│   ├── (dashboard)/        # Protected dashboard routes
│   │   ├── page.tsx        # Dashboard home
│   │   ├── trends/         # Trends page
│   │   ├── meals/          # Meals log
│   │   └── insights/       # Insights page
│   ├── auth/               # Auth routes
│   └── layout.tsx          # Root layout
├── components/
│   ├── charts/             # Recharts components
│   ├── dashboard/          # Dashboard-specific components
│   ├── insights/           # Insights cards
│   ├── layout/             # Sidebar, header
│   └── ui/                 # Reusable UI primitives
├── lib/
│   ├── supabase/           # Supabase clients & queries
│   └── utils.ts            # Helper functions
└── types/
    └── database.ts         # TypeScript types
```

## Authentication

Uses Supabase Magic Link authentication. Users sign in with the same email as their Shudo iOS app to access their data.

## Design System

Dark theme matching the iOS app:
- Background: `#090A0E` (paper)
- Elevated: `#0E1017`
- Accent: `#4385F4` (electric blue)
- Success: `#46D279` (fresh green)
- Macro colors: Protein `#8BB5FE`, Carbs `#46D279`, Fat `#F4C143`
