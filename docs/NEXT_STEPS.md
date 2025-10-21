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

## Implementation — numbered steps

### 1) Create a DB table for jobs + webhook idempotency

File: `prisma/schema.prisma`

```prisma
model AIJob {
  id           String   @id @default(cuid())
  responseId   String   @unique
  status       String   // queued | in_progress | completed | failed | cancelled
  input        Json
  outputText   String?
  error        String?
  createdAt    DateTime @default(now())
  updatedAt    DateTime @updatedAt
}

model WebhookEvent {
  // Use Standard Webhooks' `webhook-id` header as an idempotency key
  id         String   @id
  type       String
  payload    Json
  receivedAt DateTime @default(now())
}
```

Migrate:

```bash
npx prisma migrate dev -n "ai_jobs_and_webhooks"
```

(Standard Webhooks recommends deduplicating by webhook-id.)

### 2) Server: create the job in background mode

File: `app/api/ai/request/route.ts`

```ts
// Ensure Node runtime (required for SDK, SSE, and crypto)
export const runtime = "nodejs";

import { NextResponse } from "next/server";
import OpenAI from "openai";
import { prisma } from "@/server/prisma";
import { z } from "zod";

const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

const Body = z.object({
  // Whatever your UI sends
  prompt: z.string().min(1),
  imageUrls: z.array(z.string().url()).optional(),
  userId: z.string().optional(),
});

export async function POST(req: Request) {
  const body = Body.parse(await req.json());

  // 1) Create background job with the Responses API
  const resp = await client.responses.create({
    model: "gpt-5",              // background job model
    input: [
      { role: "user", content: [{ type: "input_text", text: body.prompt }] },
      ...(body.imageUrls ?? []).map((url) => ({
        role: "user",
        content: [{ type: "input_image", image_url: url }],
      })),
    ],
    background: true,            // <-- critical
  });

  // 2) Persist mapping from responseId -> job
  const job = await prisma.aIJob.create({
    data: {
      responseId: resp.id,
      status: resp.status ?? "queued",
      input: body,
    },
  });

  // 3) Return immediately; UI will subscribe for updates
  return NextResponse.json({ jobId: job.id, responseId: resp.id, status: job.status }, { status: 202 });
}
```

OpenAI background mode is designed to avoid timeouts on long‑running work.

### 3) Server: verify and handle OpenAI webhooks

In the OpenAI dashboard, add a webhook endpoint (subscribe to `response.completed`). Verify signatures per Standard Webhooks or via the OpenAI SDK’s helper `webhooks.unwrap`.

File: `app/api/openai/webhook/route.ts`

```ts
export const runtime = "nodejs";

import OpenAI from "openai";
import { prisma } from "@/server/prisma";
import { events } from "@/server/events"; // tiny EventEmitter broker (see next step)

const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

/**
 * IMPORTANT: we must read the raw body string for signature verification.
 * In Next.js App Router, `await request.text()` gives you the raw body.
 */
export async function POST(request: Request) {
  const rawBody = await request.text();
  const headers: Record<string, string> = {};
  request.headers.forEach((v, k) => (headers[k] = v));

  try {
    const event = await client.webhooks.unwrap(rawBody, headers, {
      secret: process.env.OPENAI_WEBHOOK_SECRET!,
    });

    // Idempotency: store webhook-id; skip if we've seen it
    const whId = headers["webhook-id"];
    if (whId) {
      const existing = await prisma.webhookEvent.findUnique({ where: { id: whId } });
      if (existing) return new Response(null, { status: 200 });
      await prisma.webhookEvent.create({
        data: { id: whId, type: event.type, payload: event as any },
      });
    }

    if (event.type === "response.completed") {
      const responseId = (event.data as any).id;

      // Retrieve the final output text (helper below mirrors OpenAI docs)
      const resp = await client.responses.retrieve(responseId);
      const outputText = (resp.output ?? [])
        .filter((it: any) => it.type === "message")
        .flatMap((it: any) => it.content)
        .filter((c: any) => c.type === "output_text")
        .map((c: any) => c.text)
        .join("");

      // Update the job
      const job = await prisma.aIJob.update({
        where: { responseId },
        data: { status: "completed", outputText },
      });

      // Notify any live subscribers
      events.emit(`job:${job.id}`, { status: "completed", outputText });
    }

    return new Response(null, { status: 200 });
  } catch (err: any) {
    // If signature fails, return 400 so OpenAI retries (up to ~72h with backoff)
    return new Response("Invalid signature", { status: 400 });
  }
}
```

– OpenAI’s webhook guide + Responses background mode: purpose-built for long jobs and webhooks.
– Standard Webhooks explains signature format and using webhook-id to dedupe.

### 4) Server: light event broker + SSE stream for the UI

File: `server/events.ts`

```ts
import { EventEmitter } from "events";
export const events = new EventEmitter();
events.setMaxListeners(0);
```

File: `app/api/ai/events/[jobId]/route.ts`

```ts
export const runtime = "nodejs";

import { events } from "@/server/events";
import { prisma } from "@/server/prisma";

export async function GET(_req: Request, { params }: { params: { jobId: string } }) {
  const encoder = new TextEncoder();

  const stream = new ReadableStream({
    start(controller) {
      const send = (data: any) => controller.enqueue(encoder.encode(`data: ${JSON.stringify(data)}\n\n`));
      const onUpdate = (payload: any) => send(payload);

      // If already completed, return immediately then close
      prisma.aIJob.findUnique({ where: { id: params.jobId } }).then((job) => {
        if (job?.status === "completed") {
          send({ status: "completed", outputText: job.outputText });
          controller.close();
        }
      });

      events.on(`job:${params.jobId}`, onUpdate);
      const keepalive = setInterval(() => controller.enqueue(encoder.encode(`: ping\n\n`)), 25000);

      return () => {
        events.off(`job:${params.jobId}`, onUpdate);
        clearInterval(keepalive);
        controller.close();
      };
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
    },
  });
}
```

### 5) Client: create job + subscribe

File: `app/(ui)/hooks/useBackgroundAI.ts`

```ts
import { useEffect, useState } from "react";

export function useBackgroundAI() {
  const [state, setState] = useState<{ jobId?: string; status?: string; outputText?: string; error?: string }>({});

  async function start(prompt: string, imageUrls?: string[]) {
    const res = await fetch("/api/ai/request", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prompt, imageUrls }),
    });
    const { jobId, status } = await res.json();
    setState({ jobId, status });

    const es = new EventSource(`/api/ai/events/${jobId}`);
    es.onmessage = (e) => {
      const data = JSON.parse(e.data);
      setState((s) => ({ ...s, ...data }));
      if (data.status === "completed" || data.status === "failed") es.close();
    };
  }

  return { ...state, start };
}
```

Configure OpenAI Webhook (dashboard)

- Create endpoint `https://<your-domain>/api/openai/webhook`
- Subscribe to `response.completed` (and optionally `response.failed`, etc.)
- Copy the signing secret → set `OPENAI_WEBHOOK_SECRET`

Why these decisions

- Background mode removes the need to increase timeouts and is the officially supported solution to avoid client/server time limits for long reasoning tasks.
- Webhooks + idempotency make the pipeline reliable under retries, network issues, or duplicate deliveries (use webhook-id to dedupe).
- SSE is minimal and deploys cleanly on serverless; you don’t need to stand up a separate WebSocket infra.

Alternatives considered (and why not chosen)

- “Just increase timeouts”: brittle on serverless platforms and still risks client disconnects.
- Polling the Responses API: workable, but wasteful and slower to reflect completion; webhooks notify you instantly.
- WebSockets: great for high‑frequency bi‑directional UIs, but SSE is simpler to operate for one‑way “job finished” events.

### 6) Fix slow Meal image loading with a proper media pipeline (derivatives, CDN, blur placeholders)

Thought process & approach

Laggy images are almost always due to shipping original, large files directly to clients. Create responsive derivatives (WebP/AVIF), deliver via CDN with caching, and use LQIP/blur placeholders so the UI feels instant. Next.js `<Image />` already handles srcset/sizes; you only need to provide reasonable widths, blurDataURL, and correct cache headers.

Allow your image host in Next.js

File: `next.config.ts`

```ts
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  images: {
    remotePatterns: [
      { protocol: "https", hostname: "your-cdn.example.com" }, // S3+CloudFront, R2, etc.
    ],
    // Optional: tune device/image sizes to your layout
    deviceSizes: [360, 640, 768, 1024, 1280, 1536],
    imageSizes: [256, 384, 512, 640, 768],
  },
};

export default nextConfig;
```

On upload, create derivatives + LQIP (`sharp`) and set cache headers

File: `app/api/upload/meal-image/route.ts`

```ts
export const runtime = "nodejs";

import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import sharp from "sharp";

const s3 = new S3Client({ region: process.env.AWS_REGION });

export async function POST(req: Request) {
  const form = await req.formData();
  const file = form.get("file") as File;
  const mealId = String(form.get("mealId"));

  const buf = Buffer.from(await file.arrayBuffer());

  // Generate responsive sizes
  const sizes = [320, 640, 960, 1280];
  const uploads = await Promise.all(
    sizes.map(async (w) => {
      const webp = await sharp(buf).rotate().resize({ width: w }).webp({ quality: 78 }).toBuffer();
      const Key = `meals/${mealId}/${w}.webp`;
      await s3.send(
        new PutObjectCommand({
          Bucket: process.env.AWS_BUCKET!,
          Key,
          Body: webp,
          ContentType: "image/webp",
          CacheControl: "public, max-age=31536000, immutable",
        })
      );
      return { w, url: `https://${process.env.CDN_HOST!}/${Key}` };
    })
  );

  // Low‑quality placeholder (base64)
  const blur = await sharp(buf).resize({ width: 32 }).webp({ quality: 30 }).toBuffer();
  const blurDataURL = `data:image/webp;base64,${blur.toString("base64")}`;

  return new Response(
    JSON.stringify({ images: uploads, blurDataURL }),
    { headers: { "Content-Type": "application/json" } }
  );
}
```

Render Meal images with `<Image />`, lazy loading, and blur placeholders

File: `components/meals/MealCard.tsx`

```tsx
import Image from "next/image";

export function MealCard({ meal }: { meal: { title: string; images: { w: number; url: string }[]; blurDataURL: string } }) {
  // pick the largest as src; Next will select the right size
  const src = meal.images.sort((a, b) => b.w - a.w)[0]?.url ?? "";
  return (
    <div className="rounded-md border overflow-hidden">
      <div className="relative aspect-[16/9] bg-neutral-100">
        <Image
          src={src}
          alt={meal.title}
          fill
          // Let Next produce responsive variants; give the layout a sizes hint:
          sizes="(max-width: 640px) 100vw, (max-width: 1024px) 66vw, 640px"
          placeholder="blur"
          blurDataURL={meal.blurDataURL}
          loading="lazy"
        />
      </div>
      {/* ...text & actions (see next section) */}
    </div>
  );
}
```

Why these decisions

- Transforming originals to WebP (or AVIF) in multiple widths radically cuts bytes while preserving quality; strong cache headers eliminate repeat cost.
- Blur placeholders make perception instant; Next/Image handles responsive delivery automatically once your host is whitelisted.

Alternatives

- Cloudinary/Imgix transformations on the fly (f_auto,q_auto,c_fill,w_...)—excellent developer ergonomics; if you prefer managed media, plug that in and skip `sharp`.
- Client‑only downscaling: still downloads the original; not acceptable for performance.

### 7) Fix Meal-card text overlapping the 3‑dot actions (UI/UX + accessibility)

Thought process & approach

The overlap typically comes from absolutely positioned action buttons over a fluid text block with no reserved space. Switch to a two‑column grid, clamp the text to 2 lines with ellipsis, and use an accessible menu button. This prevents overlap in all breakpoints and screen sizes.

Use a grid with a fixed actions column; clamp long titles/notes

File: `components/meals/MealCard.tsx`

```tsx
import { Menu } from "@headlessui/react"; // or Radix UI if preferred

export function MealCard({ meal }: { meal: { title: string; notes?: string } }) {
  return (
    <div className="rounded-md border overflow-hidden">
      {/* image block here */}

      <div className="grid grid-cols-[1fr_auto] items-start gap-3 p-3">
        <div>
          <h3 className="font-medium leading-tight line-clamp-2">{meal.title}</h3>
          {meal.notes ? (
            <p className="text-sm text-neutral-600 line-clamp-2 mt-1">{meal.notes}</p>
          ) : null}
        </div>

        <Menu as="div" className="relative">
          <Menu.Button
            aria-label="Meal actions"
            className="inline-flex h-8 w-8 items-center justify-center rounded-md hover:bg-neutral-100 focus:outline-none focus:ring"
          >
            ⋯
          </Menu.Button>
          <Menu.Items className="absolute right-0 z-10 mt-1 w-40 rounded-md border bg-white shadow-md">
            <Menu.Item>
              {({ active }) => (
                <button className={`w-full px-3 py-2 text-left ${active ? "bg-neutral-100" : ""}`}>Edit</button>
              )}
            </Menu.Item>
            <Menu.Item>
              {({ active }) => (
                <button className={`w-full px-3 py-2 text-left text-red-600 ${active ? "bg-neutral-100" : ""}`}>
                  Delete
                </button>
              )}
            </Menu.Item>
          </Menu.Items>
        </Menu>
      </div>
    </div>
  );
}
```

Ensure line‑clamp works

If you aren’t using Tailwind’s plugin, add it, or do vanilla CSS:

File: `styles/globals.css`

```css
.line-clamp-2 {
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
```

Why these decisions

- The grid reserves a dedicated actions column; text never collides.
- Line‑clamp keeps the card compact and prevents wrapping under the actions.
- Menu from a11y libraries provides keyboard + screen‑reader affordances you won’t get from a div with an onClick.

Alternatives

- Absolute‑position the actions and pad the text (pr-10). Works but fragile across font sizes and responsive changes.
- Custom popover: more control, but you rebuild a11y.

