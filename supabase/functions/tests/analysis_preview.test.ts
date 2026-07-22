import {
  ANALYSIS_PREVIEW_MIN_PUBLISH_CHARACTERS,
  ANALYSIS_PREVIEW_UPDATE_INTERVAL_MS,
  AnalysisPreviewPublisher,
} from "../_shared/analysis_preview.ts";
import { assertEquals } from "./assertions.ts";

Deno.test("analysis preview publisher writes immediately then throttles replacements", async () => {
  let now = 1_000;
  const published: string[] = [];
  const publisher = new AnalysisPreviewPublisher(
    (preview) => {
      published.push(preview);
      return Promise.resolve();
    },
    () => now,
  );

  await publisher.observe('{"analysis_preview":"Tiny');
  assertEquals(published, []);
  await publisher.observe('{"analysis_preview":"A rice bowl');
  assertEquals(published, ["A rice bowl"]);

  now += ANALYSIS_PREVIEW_UPDATE_INTERVAL_MS - 1;
  await publisher.observe('{"analysis_preview":"A rice bowl with chicken');
  assertEquals(published, ["A rice bowl"]);

  now += 1;
  await publisher.observe('{"analysis_preview":"A rice bowl with chicken');
  assertEquals(published, ["A rice bowl", "A rice bowl with chicken"]);
  await publisher.observe('{"analysis_preview":"A rice bowl with chicken');
  assertEquals(published, ["A rice bowl", "A rice bowl with chicken"]);
  assertEquals(ANALYSIS_PREVIEW_MIN_PUBLISH_CHARACTERS, 8);
});

Deno.test("failed fenced preview writes remain retry-safe", async () => {
  const publisher = new AnalysisPreviewPublisher(() => {
    return Promise.reject(new Error("Processing lease was replaced"));
  });
  let message = "";
  try {
    await publisher.observe('{"analysis_preview":"A complete preview fragment');
  } catch (error) {
    message = error instanceof Error ? error.message : String(error);
  }
  assertEquals(message, "Processing lease was replaced");
});
