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

		// Create Responses background job and return immediately; webhook will finalize
		const bg = await fetch("https://api.openai.com/v1/responses", {
			method: "POST",
			headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, "Content-Type": "application/json" },
			body: JSON.stringify({
				model: "gpt-5",
				background: true,
				input,
				response_format: {
					type: "json_schema",
					json_schema: { name: "NutritionExtraction", schema: RESULT_SCHEMA, strict: true }
				},
				metadata: { entry_id: entry.id, user_id },
			}),
		});
		if (!bg.ok) throw new Error(`openai responses(background) ${bg.status}: ${await bg.text()}`);
		const job = await bg.json();
		console.log("queued_response_id", job?.id, "entry", entry.id);

		// Persist raw_text for UI context while processing
		await admin.from("entries").update({ raw_text }).eq("id", entry.id);

		return new Response(JSON.stringify({ entry_id: entry.id, image_path, audio_path }), {
			headers: { "content-type": "application/json" },
		});
	} catch (err) {
		console.error(err);
		return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
	}
});


