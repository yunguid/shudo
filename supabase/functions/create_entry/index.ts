// supabase/functions/create_entry/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE);

function extractJsonObject(text: string | null | undefined): any {
    if (!text) return {};
    // Try fenced block first
    const fence = /```json[\s\S]*?```/i.exec(text);
    if (fence) {
        const inner = fence[0].replace(/```json/i, '').replace(/```$/, '');
        try { return JSON.parse(inner.trim()); } catch {}
    }
    // Try to find first JSON object by scanning braces
    const start = text.indexOf('{');
    const end = text.lastIndexOf('}');
    if (start !== -1 && end !== -1 && end > start) {
        const candidate = text.slice(start, end + 1);
        try { return JSON.parse(candidate); } catch {}
    }
    return {};
}

// Structured output JSON Schema
const RESULT_SCHEMA = {
	type: "object",
	additionalProperties: false,
	properties: {
		items: {
			type: "array",
			items: {
				type: "object",
				additionalProperties: false,
				properties: {
					name: { type: "string", minLength: 1 },
					quantity: { type: "number" },
					unit: { type: "string", enum: ["g", "ml", "piece"] },
					macros: {
						type: "object",
						additionalProperties: false,
						properties: {
							protein_g: { type: "number" },
							carbs_g: { type: "number" },
							fat_g: { type: "number" },
							calories_kcal: { type: "number" },
						},
						required: ["protein_g", "carbs_g", "fat_g", "calories_kcal"],
					},
					confidence: { type: "number", minimum: 0, maximum: 1 },
				},
				required: ["name", "quantity", "unit", "macros", "confidence"],
			},
		},
		entry_macros: {
			type: "object",
			additionalProperties: false,
			properties: {
				protein_g: { type: "number" },
				carbs_g: { type: "number" },
				fat_g: { type: "number" },
				calories_kcal: { type: "number" },
			},
			required: ["protein_g", "carbs_g", "fat_g", "calories_kcal"],
		},
		notes: { type: "string" },
	},
	required: ["items", "entry_macros"],
} as const;

serve(async (req) => {
	try {
		const authHeader = req.headers.get("Authorization") ?? "";
		const jwt = authHeader.replace("Bearer ", "");
		const supa = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
		const { data: authUser } = await supa.auth.getUser(jwt);
		if (!authUser?.user) return new Response("Unauthorized", { status: 401 });
		const user_id = authUser.user.id;

		const form = await req.formData();
		const text = (form.get("text") as string) || "";
		const timezone = (form.get("timezone") as string) || "UTC";

		// Insert a new entry in processing state
		const { data: entry, error: e1 } = await admin
			.from("entries")
			.insert({
				user_id,
				status: "processing",
				timezone_snapshot: timezone,
				has_text: Boolean(text),
			})
			.select()
			.single();
		if (e1) throw e1;

		let raw_text = text;
		let image_path: string | null = null;
		let audio_path: string | null = null;

		// Optional audio
		const audio = form.get("audio") as File | null;
		if (audio) {
			const ap = `u_${user_id}/e_${entry.id}/audio_${Date.now()}.m4a`;
			const up = await admin.storage.from("entry-audio").upload(ap, audio.stream(), {
				contentType: audio.type || "audio/m4a",
				upsert: false,
			});
			if (up.error) throw up.error;
			audio_path = ap;

			// Transcribe via OpenAI REST
			const audioBlob = await audio.arrayBuffer();
			const fd = new FormData();
			fd.append("model", "gpt-4o-transcribe");
			fd.append("file", new Blob([audioBlob], { type: audio.type || "audio/m4a" }), "voice.m4a");
			const trResp = await fetch("https://api.openai.com/v1/audio/transcriptions", {
				method: "POST",
				headers: { Authorization: `Bearer ${OPENAI_API_KEY}` },
				body: fd,
			});
			if (!trResp.ok) throw new Error(`openai transcribe ${trResp.status}: ${await trResp.text()}`);
			const trJson = await trResp.json();
			raw_text = [text, trJson.text].filter(Boolean).join("\n");
			await admin.from("entries").update({ has_audio: true, audio_path: ap }).eq("id", entry.id);
		}

		// Optional image
		const image = form.get("image") as File | null;
		if (image) {
			const ip = `u_${user_id}/e_${entry.id}/img_${Date.now()}.jpg`;
			const up = await admin.storage.from("entry-images").upload(ip, image.stream(), {
				contentType: image.type || "image/jpeg",
				upsert: false,
			});
			if (up.error) throw up.error;
			image_path = ip;
			await admin.from("entries").update({ has_image: true, image_path: ip }).eq("id", entry.id);
		}

		// Build input for Responses API (GPT-5), using image + text parts
		const input: any[] = [
			{
				role: "user",
				content: [
					{ type: "input_text", text: [
						"You are a nutrition estimation model.",
						"Given the context, produce EXACT JSON that matches the provided schema strictly.",
						"All macro values in grams (g) and calories in kcal. Output JSON only.",
						`User-described context:\n${raw_text || "None"}`,
					].join("\n") },
				],
			},
		];
		if (image_path) {
			const { data: signed } = await admin.storage.from("entry-images").createSignedUrl(image_path, 600);
			if (signed?.signedUrl) (input[0].content as any[]).push({ type: "input_image", image_url: signed.signedUrl });
		}

		// Call Responses API with gpt-5 (lower latency)
		const rr = await fetch("https://api.openai.com/v1/responses", {
			method: "POST",
			headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, "Content-Type": "application/json" },
			body: JSON.stringify({
				model: "gpt-5",
				reasoning: { effort: "minimal" },
				input,
				text: { verbosity: "low" },
				max_output_tokens: 800
			}),
		});
		if (!rr.ok) throw new Error(`openai responses ${rr.status}: ${await rr.text()}`);
		const rrJson = await rr.json();
		console.log("raw_responses_json", JSON.stringify(rrJson));
		const maybeText = rrJson.output_text ?? (Array.isArray(rrJson.output) ? rrJson.output.map((x: any) => x.content?.[0]?.text?.value).filter(Boolean).join("\n") : null);
		let payload: any = extractJsonObject(maybeText);

		// Debug log to function logs
		console.log("model_output", JSON.stringify(payload));

		// Map alt structure ext.calculation if present (observed in logs)
		const calc = (payload && payload.ext && payload.ext.calculation) ? payload.ext.calculation : null;
		let calcProtein = 0, calcCarb = 0, calcFat = 0, calcKcal = 0;
		if (calc) {
			calcProtein = Number(calc.protein) || 0;
			calcCarb = Number(calc.carb) || 0;
			calcFat = Number(calc.fat) || 0;
			calcKcal = Number(calc.calorie) || 0;
			if (!Array.isArray(payload.items) && Array.isArray(calc.items)) {
				payload.items = calc.items.map((it: any) => ({
					name: it?.name ?? "Item",
					quantity: it?.weight_grams ?? 0,
					unit: "g",
					macros: {
						protein_g: Number(it?.protein) || 0,
						carbs_g: Number(it?.carb) || 0,
						fat_g: Number(it?.fat) || 0,
						calories_kcal: Number(it?.calorie) || 0,
					},
					confidence: (it?.confidence === "high" ? 0.9 : it?.confidence === "medium" ? 0.6 : 0.3)
				}));
			}
		}

		// Coerce/repair macros if missing by summing items or using calc totals
		const toNum = (v: any) => (typeof v === "number" && isFinite(v)) ? v : parseFloat(String(v ?? "")) || 0;
		let macros = payload.entry_macros || {};
		let mProtein = toNum(macros.protein_g);
		let mCarbs = toNum((macros as any).carbs_g);
		let mFat = toNum(macros.fat_g);
		let mKcal = toNum(macros.calories_kcal);

		// If a top-level macros shape is returned (like in logs), map it
		if ((mProtein + mCarbs + mFat + mKcal) === 0 && payload && payload.macros) {
			const top = payload.macros as any;
			mProtein = toNum(top.protein_g ?? top.protein);
			mCarbs = toNum(top.carbohydrates_g ?? top.carbs_g ?? top.carb);
			mFat = toNum(top.fat_g ?? top.fat);
			mKcal = toNum(top.calories_kcal ?? payload.calories_kcal ?? top.kcal ?? top.calories);
		}
		if ((mProtein + mCarbs + mFat + mKcal) === 0 && Array.isArray(payload.items)) {
			for (const it of payload.items) {
				const mm = it?.macros || {};
				mProtein += toNum(mm.protein_g);
				mCarbs += toNum(mm.carbs_g);
				mFat += toNum(mm.fat_g);
				mKcal += toNum(mm.calories_kcal);
			}
		}
		if ((mProtein + mCarbs + mFat + mKcal) === 0 && (calcProtein + calcCarb + calcFat + calcKcal) > 0) {
			mProtein = calcProtein; mCarbs = calcCarb; mFat = calcFat; mKcal = calcKcal;
		}
		const conf = Array.isArray(payload.items) && payload.items.length
			? payload.items.reduce((acc: number, it: any) => acc + (it.confidence ?? 0), 0) / payload.items.length
			: null;

		const storedOutput = { parsed: payload, raw_text: maybeText, raw_json: rrJson } as Record<string, unknown>;
		const { error: e2 } = await admin
			.from("entries")
			.update({
				status: "complete",
				raw_text,
				model_output: storedOutput,
				protein_g: mProtein,
				carbs_g: mCarbs,
				fat_g: mFat,
				calories_kcal: mKcal,
				confidence: conf,
				processed_at: new Date().toISOString(),
			})
			.eq("id", entry.id);
		if (e2) throw e2;

		return new Response(JSON.stringify({ entry_id: entry.id, image_path, audio_path }), {
			headers: { "content-type": "application/json" },
		});
	} catch (err) {
		console.error(err);
		return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
	}
});


