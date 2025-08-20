// supabase/functions/create_entry/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE);

// Upload constraints
const MAX_IMAGE_BYTES = 6 * 1024 * 1024;  // 6MB
const MAX_AUDIO_BYTES = 25 * 1024 * 1024; // 25MB

const ALLOWED_IMAGE_TYPES = new Set(["image/jpeg", "image/jpg", "image/png", "image/webp"]);
const ALLOWED_AUDIO_TYPES = new Set(["audio/m4a", "audio/aac", "audio/mp4", "audio/mpeg", "audio/mp3", "audio/wav"]);

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
		notes: { type: ["string", "null"] },
	},
	required: ["items", "entry_macros", "notes"],
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

		// Validate optional uploads early to avoid creating orphan entries
		const audio = form.get("audio") as File | null;
		if (audio) {
			if (audio.size > MAX_AUDIO_BYTES) {
				return new Response(JSON.stringify({ error: "Audio too large (max 25MB)" }), { status: 413, headers: { "content-type": "application/json" } });
			}
			if (audio.type && !ALLOWED_AUDIO_TYPES.has(audio.type)) {
				return new Response(JSON.stringify({ error: `Unsupported audio type: ${audio.type}` }), { status: 415, headers: { "content-type": "application/json" } });
			}
		}

		const image = form.get("image") as File | null;
		if (image) {
			if (image.size > MAX_IMAGE_BYTES) {
				return new Response(JSON.stringify({ error: "Image too large (max 6MB)" }), { status: 413, headers: { "content-type": "application/json" } });
			}
			if (image.type && !ALLOWED_IMAGE_TYPES.has(image.type)) {
				return new Response(JSON.stringify({ error: `Unsupported image type: ${image.type}` }), { status: 415, headers: { "content-type": "application/json" } });
			}
		}

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
				role: "system",
				content: [
					{ type: "input_text", text: [
						"You are a nutrition extraction model.",
						"Respond ONLY with JSON that matches the provided schema.",
						"Every required field must be present. Do not include extra keys.",
					].join("\n") },
				],
			},
			{
				role: "user",
				content: [
					{ type: "input_text", text: [
						"Extract nutrition info.",
						`User-described context:\n${raw_text || "None"}`,
					].join("\n") },
				],
			},
		];
		if (image_path) {
			const { data: signed } = await admin.storage.from("entry-images").createSignedUrl(image_path, 600);
			// Attach image to the user message (index 1). 'system' messages cannot include images.
			if (signed?.signedUrl) (input[1].content as any[]).push({ type: "input_image", image_url: signed.signedUrl });
		}

		// Call Responses API with gpt-5 + Structured Outputs (text.format)
		const rr = await fetch("https://api.openai.com/v1/responses", {
			method: "POST",
			headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, "Content-Type": "application/json" },
			body: JSON.stringify({
				model: "gpt-5",
				reasoning: { effort: "medium" },
				input,
				text: {
					format: {
						type: "json_schema",
						name: "NutritionExtraction",
						schema: RESULT_SCHEMA,
						strict: true
					},
					verbosity: "low"
				},
			}),
		});
		if (!rr.ok) throw new Error(`openai responses ${rr.status}: ${await rr.text()}`);
			const rrJson = await rr.json();
		console.log("raw_responses_json", JSON.stringify(rrJson));
		// Prefer structured parsed output if present; otherwise fall back to output_text
		let payload: any = rrJson.output_parsed ?? null;
		if (!payload && Array.isArray(rrJson.output)) {
			for (const x of rrJson.output) {
				if (Array.isArray(x?.content)) {
					for (const c of x.content) {
						if (c?.parsed) { payload = c.parsed; break; }
					}
				}
			}
		}
		let maybeText = rrJson.output_text as string | null | undefined;
		if (!payload && !maybeText && Array.isArray(rrJson.output)) {
			maybeText = rrJson.output
				.map((x: any) => {
					const c = Array.isArray(x?.content) ? x.content[0] : null;
					return typeof c?.text === "string" ? c.text : null;
				})
				.filter(Boolean)
				.join("\n");
		}
		if (!payload) payload = extractJsonObject(maybeText);

		// Fallback: if payload missing required keys, retry with JSON mode
		const hasValid = payload && typeof payload === "object" && Array.isArray(payload.items) && payload.entry_macros;
		if (!hasValid) {
			const rr2 = await fetch("https://api.openai.com/v1/responses", {
				method: "POST",
				headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, "Content-Type": "application/json" },
				body: JSON.stringify({
					model: "gpt-5",
					input,
					text: { format: { type: "json_object" }, verbosity: "low" },
					max_output_tokens: 1600
				})
			});
			if (rr2.ok) {
				const j2 = await rr2.json();
				payload = j2.output_parsed ?? extractJsonObject(j2.output_text);
			}
		}

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

		// Map alternative "meals" structure into expected shape
		if (payload && Array.isArray(payload.meals) && payload.meals.length > 0) {
			const meals: any[] = payload.meals;
			const normalizedItems: any[] = [];
			let tProtein = 0, tCarbs = 0, tFat = 0, tKcal = 0;

			for (const meal of meals) {
				const mealMacros = (meal?.macros_g || meal?.macros || {}) as any;
				tProtein += Number(mealMacros.protein_g ?? mealMacros.protein ?? 0) || 0;
				tCarbs += Number(mealMacros.carbs_g ?? mealMacros.carbohydrates_g ?? mealMacros.carbohydrates ?? mealMacros.carb ?? 0) || 0;
				tFat += Number(mealMacros.fat_g ?? mealMacros.fat ?? 0) || 0;
				tKcal += Number(meal?.calories ?? mealMacros.calories_kcal ?? 0) || 0;

				const items: any[] = Array.isArray(meal?.items) ? meal.items : [];
				for (const it of items) {
					const mm = (it?.macros_g || it?.macros || {}) as any;
					const protein_g = Number(mm.protein_g ?? mm.protein ?? 0) || 0;
					const carbs_g = Number(mm.carbs_g ?? mm.carbohydrates_g ?? mm.carbohydrates ?? mm.carb ?? 0) || 0;
					const fat_g = Number(mm.fat_g ?? mm.fat ?? 0) || 0;
					const calories_kcal = Number(it?.calories ?? mm.calories_kcal ?? 0) || 0;
					const quantity = Number(it?.quantity ?? it?.weight_grams ?? 0) || 0;
					const unit = it?.unit ?? (it?.weight_grams != null ? "g" : (it?.pieces != null ? "piece" : "g"));

					normalizedItems.push({
						name: it?.name ?? "Item",
						quantity,
						unit,
						macros: { protein_g, carbs_g, fat_g, calories_kcal },
						confidence: it?.confidence ?? 0.6,
					});
				}
			}

			if (!Array.isArray(payload.items) || payload.items.length === 0) {
				payload.items = normalizedItems;
			}

			const hasEntryMacros = payload.entry_macros && typeof payload.entry_macros === "object";
			const entryTotalsZero = !hasEntryMacros || [
				Number(payload.entry_macros?.protein_g ?? 0) || 0,
				Number(payload.entry_macros?.carbs_g ?? 0) || 0,
				Number(payload.entry_macros?.fat_g ?? 0) || 0,
				Number(payload.entry_macros?.calories_kcal ?? 0) || 0,
			].every((v) => v === 0);

			if (entryTotalsZero) {
				// If meal totals are missing, compute from items
				if ((tProtein + tCarbs + tFat + tKcal) === 0 && normalizedItems.length > 0) {
					for (const it of normalizedItems) {
						tProtein += Number(it.macros?.protein_g ?? 0) || 0;
						tCarbs += Number(it.macros?.carbs_g ?? 0) || 0;
						tFat += Number(it.macros?.fat_g ?? 0) || 0;
						tKcal += Number(it.macros?.calories_kcal ?? 0) || 0;
					}
				}
				payload.entry_macros = {
					protein_g: tProtein,
					carbs_g: tCarbs,
					fat_g: tFat,
					calories_kcal: tKcal,
				};
			}
		}

		// Coerce/repair macros if missing by summing items or using calc totals
		const toNum = (v: any) => (typeof v === "number" && isFinite(v)) ? v : parseFloat(String(v ?? "")) || 0;
		let macros = payload.entry_macros || {};
		let mProtein = toNum(macros.protein_g);
		let mCarbs = toNum((macros as any).carbs_g);
		let mFat = toNum(macros.fat_g);
		let mKcal = toNum(macros.calories_kcal ?? (payload.estimated_calories ?? payload.estimated_calories_kcal));

		// If a top-level macros shape is returned (like in logs), map it
		if ((mProtein + mCarbs + mFat + mKcal) === 0 && payload) {
			const candidates = [
				(payload as any).entry_macros,
				(payload as any).macros,
				(payload as any).macros_g, // frequently seen in responses
				(payload as any).nutrition,
				(payload as any).nutrients,
				(payload as any).total, // observed shape in multi-item outputs
			];
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
		if ((mProtein + mCarbs + mFat + mKcal) === 0 && Array.isArray(payload.items)) {
			for (const it of payload.items) {
				// Items may contain nested macros or flattened nutrient keys
				const mm = it?.macros_g || it?.macros || it || {};
				mProtein += toNum(mm.protein_g ?? mm.protein);
				mCarbs += toNum(mm.carbs_g ?? mm.carbohydrates_g ?? mm.carbohydrates ?? mm.carb);
				mFat += toNum(mm.fat_g ?? mm.fat);
				mKcal += toNum(mm.calories_kcal ?? mm.kcal ?? mm.calories);
			}
		}

		// If we have macros but no calories, derive kcal from macros
		if (mKcal === 0 && (mProtein + mCarbs + mFat) > 0) {
			mKcal = mProtein * 4 + mCarbs * 4 + mFat * 9;
		}
		if ((mProtein + mCarbs + mFat + mKcal) === 0 && (calcProtein + calcCarb + calcFat + calcKcal) > 0) {
			mProtein = calcProtein; mCarbs = calcCarb; mFat = calcFat; mKcal = calcKcal;
		}
		const conf = Array.isArray(payload.items) && payload.items.length
			? payload.items.reduce((acc: number, it: any) => acc + (it.confidence ?? 0), 0) / payload.items.length
			: null;

		console.log("Macro Totals for entry:", entry.id, "mProtein:", mProtein, "mCarbs:", mCarbs, "mFat:", mFat, "mKcal:", mKcal);
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


