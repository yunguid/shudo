import { analysisPreviewFromPartialJSON } from "./analysis.ts";

// Matched to the client's 650 ms streaming poll: publishing faster than the
// app reads produces database writes no one ever observes.
export const ANALYSIS_PREVIEW_UPDATE_INTERVAL_MS = 650;
export const ANALYSIS_PREVIEW_MIN_PUBLISH_CHARACTERS = 8;

type PublishPreview = (preview: string) => Promise<void>;
type CurrentTime = () => number;

/**
 * Publishes the first useful preview immediately, then caps database writes
 * at the client's poll cadence. The processor's fenced update remains the
 * authority: a lost lease rejects the publish and stops the provider stream.
 */
export class AnalysisPreviewPublisher {
  #lastPreview: string | null = null;
  #lastPublishedAt = Number.NEGATIVE_INFINITY;

  constructor(
    private readonly publish: PublishPreview,
    private readonly now: CurrentTime = Date.now,
    private readonly intervalMs = ANALYSIS_PREVIEW_UPDATE_INTERVAL_MS,
  ) {}

  async observe(partialJSON: string): Promise<void> {
    const preview = analysisPreviewFromPartialJSON(partialJSON);
    if (
      !preview ||
      Array.from(preview).length < ANALYSIS_PREVIEW_MIN_PUBLISH_CHARACTERS ||
      preview === this.#lastPreview
    ) {
      return;
    }

    const observedAt = this.now();
    if (observedAt - this.#lastPublishedAt < this.intervalMs) return;

    await this.publish(preview);
    this.#lastPreview = preview;
    this.#lastPublishedAt = observedAt;
  }
}
