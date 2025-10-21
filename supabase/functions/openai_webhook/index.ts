// supabase/functions/openai_webhook/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import OpenAI from "https://esm.sh/openai@4.67.3";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const OPENAI_WEBHOOK_SECRET = Deno.env.get("OPENAI_WEBHOOK_SECRET") || "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE);
const oai = new OpenAI({ apiKey: OPENAI_API_KEY });

// Helpers ------------------------------------------------------------
function decodeWebhookSecret(secret: string): Uint8Array {
	let s = secret.trim();
	if (s.startsWith("whsec_")) s = s.slice(6);
	try {
		const bin = atob(s);
		return new Uint8Array([...bin].map((c) => c.charCodeAt(0)));
	} catch {
		return new TextEncoder().encode(secret);
	}
}

async function hmacSha256HexBytes(secretBytes: Uint8Array, payload: string): Promise<string> {
	const key = await crypto.subtle.importKey("raw", secretBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
	const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload));
	return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function hmacSha256B64Bytes(secretBytes: Uint8Array, payload: string): Promise<string> {
	const key = await crypto.subtle.importKey("raw", secretBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
	const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload));
	const bytes = new Uint8Array(sig);
	let bin = ""; for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
	return btoa(bin);
}

function parseStandardWebhookSignature(header: string | null): { scheme: string; values: Record<string, string[]> } {
	// Expected format per Standard Webhooks: comma-separated k=v pairs; multiple v1 allowed
	const out: Record<string, string[]> = {};
	if (!header) return { scheme: "", values: out };
	for (const part of header.split(",")) {
		const [k, v] = part.split("=").map((s) => s.trim());
		if (!k || !v) continue;
		if (!out[k]) out[k] = [];
		out[k].push(v);
	}
	return { scheme: "v1", values: out };
}

async function verifyStandardWebhook(rawBody: string, headers: Headers): Promise<boolean> {
	if (!OPENAI_WEBHOOK_SECRET) return true; // allow if no secret set

	const secretBytes = decodeWebhookSecret(OPENAI_WEBHOOK_SECRET);

	// Standard Webhooks headers
	const whSig = headers.get("webhook-signature");
	let whTs = headers.get("webhook-timestamp");
	if (whSig) {
		const parsed = parseStandardWebhookSignature(whSig);
		if (!whTs) whTs = (parsed.values["t"] || [])[0];
		const candidates: string[] = [];
		candidates.push(...(parsed.values["v1"] || []));
		candidates.push(...(parsed.values["sig"] || []));
		candidates.push(...(parsed.values["s"] || []));
		candidates.push(...(parsed.values["sha256"] || []));
		if (whTs && candidates.length > 0) {
			const base = `${whTs}.${rawBody}`;
			const expectedHex = await hmacSha256HexBytes(secretBytes, base);
			const expectedB64 = await hmacSha256B64Bytes(secretBytes, base);
			for (const got of candidates) {
				if (timingSafeEqualHex(got, expectedHex) || got === expectedB64) return true;
			}
		}
	}
	// Fallback: older Svix-style headers used by some providers
	const sxId = headers.get("svix-id");
	const sxTs = headers.get("svix-timestamp");
	const sxSig = headers.get("svix-signature");
	if (sxId && sxTs && sxSig) {
		// svix-signature contains space/comma separated entries like: v1,BASE64=...
		const parts = sxSig.split(" ").flatMap((s) => s.split(","));
		const candidates = parts.filter((p) => p.startsWith("v1,")).map((p) => p.replace(/^v1,/, ""));
		const base = `${sxTs}.${rawBody}`;
		const expectedB64 = await hmacSha256B64Bytes(secretBytes, base);
		for (const got of candidates) { if (got === expectedB64) return true; }
		return false;
	}
	// If no recognizable headers, allow only if secret is empty (dev)
	return !OPENAI_WEBHOOK_SECRET;
}

function timingSafeEqualHex(a: string, b: string): boolean {
	if (a.length !== b.length) return false;
	let out = 0;
	for (let i = 0; i < a.length; i++) { out |= a.charCodeAt(i) ^ b.charCodeAt(i); }
	return out === 0;
}

function extractJsonObject(text: string | null | undefined): any {
	if (!text) return {};
	const fence = /```json[\s\S]*?```/i.exec(text);
	if (fence) {
		const inner = fence[0].replace(/```json/i, '').replace(/```$/, '');
		try { return JSON.parse(inner.trim()); } catch {}
	}
	const start = text.indexOf('{');
	const end = text.lastIndexOf('}');
	if (start !== -1 && end !== -1 && end > start) {
		const candidate = text.slice(start, end + 1);
		try { return JSON.parse(candidate); } catch {}
	}
	return {};
}

// Main handler -------------------------------------------------------
serve(async (req) => {
	try {
		console.log("Webhook received, method:", req.method);
		console.log("Headers:", Object.fromEntries(req.headers.entries()));
		
		if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

		// We need the raw text for signature verification
		const rawBody = await req.text();
		console.log("Raw body received, length:", rawBody.length);
		let event: any;
		
		const ok = await verifyStandardWebhook(rawBody, req.headers);
		console.log("Signature verification result:", ok);
		if (!ok) {
			console.warn("Invalid webhook signature");
			return new Response("Unauthorized", { status: 401 });
		}
		try { 
			event = JSON.parse(rawBody); 
		} catch { 
			return new Response("Bad Request", { status: 400 }); 
		}

		// We expect response.completed events; obtain the response id robustly
		const responseId = (event?.data?.id) || (event?.response?.id) || event?.id;
		const eventType = event?.type || event?.event || "";
		if (eventType && eventType !== "response.completed") {
			console.log("ignoring event type", eventType);
			return new Response(null, { status: 200 });
		}
		if (!responseId) {
			console.log("webhook missing response id", event?.type);
			return new Response(null, { status: 200 });
		}

		// Retrieve final response to get structured output and metadata
		const r = await fetch(`https://api.openai.com/v1/responses/${responseId}`, {
			headers: { Authorization: `Bearer ${OPENAI_API_KEY}` }
		});
		if (!r.ok) {
			console.error("responses.retrieve", r.status, await r.text());
			// Allow test events or transient retrieval issues without forcing retries
			return new Response(null, { status: 200 });
		}
		const resp = await r.json();
		const meta = (resp?.metadata ?? {}) as Record<string, any>;
		const entryId: string | undefined = meta["entry_id"] ?? meta["entryId"];
		if (!entryId) {
			console.error("missing entry_id metadata on response", responseId);
			return new Response(null, { status: 200 });
		}

		// Extract structured output
		let payload: any = resp.output_parsed ?? null;
		if (!payload && Array.isArray(resp.output)) {
			for (const x of resp.output) {
				if (Array.isArray(x?.content)) {
					for (const c of x.content) {
						if (c?.parsed) { payload = c.parsed; break; }
					}
				}
			}
		}
		let maybeText: string | null | undefined = resp.output_text;
		if (!payload && !maybeText && Array.isArray(resp.output)) {
			maybeText = resp.output
				.map((x: any) => {
					const c = Array.isArray(x?.content) ? x.content[0] : null;
					return typeof c?.text === "string" ? c.text : null;
				})
				.filter(Boolean)
				.join("\n");
		}
		if (!payload) payload = extractJsonObject(maybeText);

		// Compute macros similar to create_entry logic
		const toNum = (v: any) => (typeof v === "number" && isFinite(v)) ? v : parseFloat(String(v ?? "")) || 0;
		let macros = payload?.entry_macros || {};
		let mProtein = toNum(macros.protein_g);
		let mCarbs = toNum((macros as any)?.carbs_g);
		let mFat = toNum(macros.fat_g);
		let mKcal = toNum(macros.calories_kcal ?? (payload?.estimated_calories ?? payload?.estimated_calories_kcal));

		if ((mProtein + mCarbs + mFat + mKcal) === 0 && payload) {
			const candidates = [payload.entry_macros, payload.macros, payload.macros_g, payload.nutrition, payload.nutrients, payload.total];
			for (const top of candidates) {
				if (!top) continue;
				const nested = (top as any).macros_g || (top as any).macros || top;
				mProtein = toNum(nested.protein_g ?? nested.protein);
				mCarbs = toNum(nested.carbohydrates_g ?? nested.carbs_g ?? nested.carb ?? nested.carbohydrates);
				mFat = toNum(nested.fat_g ?? nested.fat);
				mKcal = toNum(
					nested.calories_kcal ??
					(top as any).calories_kcal ??
					(payload as any).calories_kcal ??
					(payload as any).estimated_calories_kcal ??
					(payload as any).estimated_calories ??
					(top as any).kcal ?? (top as any).calories
				);
				if ((mProtein + mCarbs + mFat + mKcal) > 0) break;
			}
		}
		if ((mProtein + mCarbs + mFat + mKcal) === 0 && Array.isArray(payload?.items)) {
			for (const it of payload.items) {
				const mm = it?.macros_g || it?.macros || it || {};
				mProtein += toNum(mm.protein_g ?? mm.protein);
				mCarbs += toNum(mm.carbs_g ?? mm.carbohydrates_g ?? mm.carbohydrates ?? mm.carb);
				mFat += toNum(mm.fat_g ?? mm.fat);
				mKcal += toNum(mm.calories_kcal ?? mm.kcal ?? mm.calories);
			}
		}
		if (mKcal === 0 && (mProtein + mCarbs + mFat) > 0) mKcal = mProtein * 4 + mCarbs * 4 + mFat * 9;

		const conf = Array.isArray(payload?.items) && payload.items.length
			? payload.items.reduce((acc: number, it: any) => acc + (it?.confidence ?? 0), 0) / payload.items.length
			: null;

		const storedOutput = { parsed: payload, raw_text: maybeText, raw_json: resp } as Record<string, unknown>;

		const { error: e2 } = await admin
			.from("entries")
			.update({
				status: "complete",
				model_output: storedOutput,
				protein_g: mProtein,
				carbs_g: mCarbs,
				fat_g: mFat,
				calories_kcal: mKcal,
				confidence: conf,
				processed_at: new Date().toISOString(),
			})
			.eq("id", entryId);
		if (e2) throw e2;

		return new Response(null, { status: 200 });
	} catch (err) {
		console.error(err);
		return new Response(null, { status: 500 });
	}
});

