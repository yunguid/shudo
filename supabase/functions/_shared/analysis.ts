export const RESULT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    title: { type: "string", minLength: 1, maxLength: 120 },
    items: {
      type: "array",
      maxItems: 30,
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          name: { type: "string", minLength: 1 },
          amount: { type: "string", minLength: 1 },
          protein_g: { type: "number", minimum: 0 },
          carbs_g: { type: "number", minimum: 0 },
          fat_g: { type: "number", minimum: 0 },
          calories_kcal: { type: "number", minimum: 0 },
          confidence: { type: "number", minimum: 0, maximum: 1 },
        },
        required: [
          "name",
          "amount",
          "protein_g",
          "carbs_g",
          "fat_g",
          "calories_kcal",
          "confidence",
        ],
      },
    },
    totals: {
      type: "object",
      additionalProperties: false,
      properties: {
        protein_g: { type: "number", minimum: 0 },
        carbs_g: { type: "number", minimum: 0 },
        fat_g: { type: "number", minimum: 0 },
        calories_kcal: { type: "number", minimum: 0 },
      },
      required: ["protein_g", "carbs_g", "fat_g", "calories_kcal"],
    },
    confidence: { type: "number", minimum: 0, maximum: 1 },
    notes: { type: ["string", "null"] },
  },
  required: ["title", "items", "totals", "confidence", "notes"],
} as const;

export type ParsedAnalysisItem = {
  name: string;
  amount: string;
  protein_g: number;
  carbs_g: number;
  fat_g: number;
  calories_kcal: number;
  confidence: number;
};

export type ParsedAnalysis = {
  title: string;
  items: ParsedAnalysisItem[];
  totals: {
    protein_g: number;
    carbs_g: number;
    fat_g: number;
    calories_kcal: number;
  };
  confidence: number;
  notes: string | null;
};

export function responseOutputText(response: Record<string, unknown>): string {
  if (typeof response.output_text === "string" && response.output_text) {
    return response.output_text;
  }
  const chunks: string[] = [];
  const output = Array.isArray(response.output) ? response.output : [];
  for (const item of output) {
    if (!item || typeof item !== "object") continue;
    const content = Array.isArray((item as Record<string, unknown>).content)
      ? (item as Record<string, unknown>).content as unknown[]
      : [];
    for (const part of content) {
      if (!part || typeof part !== "object") continue;
      const text = (part as Record<string, unknown>).text;
      if (typeof text === "string") chunks.push(text);
    }
  }
  return chunks.join("");
}

function finiteNonnegative(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    throw new Error(`Invalid analysis value: ${label}`);
  }
  return Math.round(value * 10) / 10;
}

function unitInterval(value: unknown, label: string): number {
  if (
    typeof value !== "number" || !Number.isFinite(value) || value < 0 ||
    value > 1
  ) {
    throw new Error(`Invalid analysis value: ${label}`);
  }
  return Math.round(value * 10) / 10;
}

function nonemptyString(value: unknown, label: string): string {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error(`Invalid analysis value: ${label}`);
  }
  return value.trim();
}

function parseItem(payload: unknown, index: number): ParsedAnalysisItem {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error(`Invalid analysis value: items[${index}]`);
  }
  const item = payload as Record<string, unknown>;
  return {
    name: nonemptyString(item.name, `items[${index}].name`),
    amount: nonemptyString(item.amount, `items[${index}].amount`),
    protein_g: finiteNonnegative(
      item.protein_g,
      `items[${index}].protein_g`,
    ),
    carbs_g: finiteNonnegative(item.carbs_g, `items[${index}].carbs_g`),
    fat_g: finiteNonnegative(item.fat_g, `items[${index}].fat_g`),
    calories_kcal: finiteNonnegative(
      item.calories_kcal,
      `items[${index}].calories_kcal`,
    ),
    confidence: unitInterval(item.confidence, `items[${index}].confidence`),
  };
}

export function parseAnalysis(payload: unknown): ParsedAnalysis {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("Analysis was not an object");
  }
  const object = payload as Record<string, unknown>;
  if (!Array.isArray(object.items) || object.items.length > 30) {
    throw new Error("Analysis items were invalid");
  }
  const totals = object.totals;
  if (!totals || typeof totals !== "object" || Array.isArray(totals)) {
    throw new Error("Analysis totals were missing");
  }
  const title = nonemptyString(object.title, "title");
  if (title.length > 120) throw new Error("Invalid analysis value: title");
  if (!("notes" in object)) throw new Error("Analysis notes were missing");
  if (object.notes !== null && typeof object.notes !== "string") {
    throw new Error("Invalid analysis value: notes");
  }
  const notes = typeof object.notes === "string"
    ? object.notes.trim().slice(0, 1_000) || null
    : null;
  const totalValues = totals as Record<string, unknown>;
  return {
    title,
    items: object.items.map(parseItem),
    totals: {
      protein_g: finiteNonnegative(totalValues.protein_g, "protein_g"),
      carbs_g: finiteNonnegative(totalValues.carbs_g, "carbs_g"),
      fat_g: finiteNonnegative(totalValues.fat_g, "fat_g"),
      calories_kcal: finiteNonnegative(
        totalValues.calories_kcal,
        "calories_kcal",
      ),
    },
    confidence: unitInterval(object.confidence, "confidence"),
    notes,
  };
}
