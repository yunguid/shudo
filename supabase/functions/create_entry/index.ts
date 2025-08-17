// supabase/functions/create_entry/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import OpenAI from "https://deno.land/x/openai@v4.52.0/mod.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const openai = new OpenAI({ apiKey: OPENAI_API_KEY });
const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE);

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
				required: ["name", "macros"],
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

			// Transcribe
			const audioBlob = await audio.arrayBuffer();
			const audioFile = new File([audioBlob], "voice.m4a", { type: audio.type || "audio/m4a" });
			const tr = await openai.audio.transcriptions.create({
				model: "gpt-4o-transcribe",
				file: audioFile,
			});
			raw_text = [text, tr.text].filter(Boolean).join("\n");
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

		// Build inputs
		const content: any[] = [
			{
				type: "input_text",
				text: [
					"You are a nutrition estimation model.",
					"Given the context, produce exact JSON that matches the provided schema.",
					"If quantities are unclear, estimate realistically from the image and text.",
					"All macro values in grams (g) and calories in kcal.",
					`User-described context:\n${raw_text || "None"}`,
				].join("\n"),
			},
		];
		if (image_path) {
			const { data: signed } = await admin.storage.from("entry-images").createSignedUrl(image_path, 600);
			if (signed?.signedUrl) content.push({ type: "input_image", image_url: signed.signedUrl });
		}

		// Structured outputs call
		const resp = await openai.responses.create({
			model: "gpt-5",
			reasoning: { effort: "high" },
			input: [{ role: "user", content }],
			response_format: {
				type: "json_schema",
				json_schema: { name: "macro_payload", schema: RESULT_SCHEMA, strict: true },
			},
		});

		const payload = JSON.parse(resp.output_text);
		const macros = payload.entry_macros || {};
		const conf = Array.isArray(payload.items) && payload.items.length
			? payload.items.reduce((acc: number, it: any) => acc + (it.confidence ?? 0), 0) / payload.items.length
			: null;

		const { error: e2 } = await admin
			.from("entries")
			.update({
				status: "complete",
				raw_text,
				model_output: payload,
				protein_g: macros.protein_g,
				carbs_g: macros.carbs_g,
				fat_g: macros.fat_g,
				calories_kcal: macros.calories_kcal,
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


