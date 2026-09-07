import type { VideoChapter } from "./twitch.ts";

/**
 * Extract Bazaar chapter time ranges from VOD chapters.
 * Returns array in format: [start1_sec, end1_sec, start2_sec, end2_sec, ...]
 */
export function extractBazaarChapters(
  chapters: VideoChapter[],
  videoLengthSeconds: number,
  bazaarGameId: string,
): number[] {
  const bazaarSegments: number[] = [];

  // Sort chapters by position
  const sortedChapters = [...chapters].sort(
    (a, b) => a.positionMilliseconds - b.positionMilliseconds,
  );

  for (let i = 0; i < sortedChapters.length; i++) {
    const chapter = sortedChapters[i];

    // Check if this chapter is for The Bazaar
    const isBazaar = chapter.game?.id === bazaarGameId ||
      chapter.game?.name?.toLowerCase() === "the bazaar";

    if (isBazaar) {
      // Chapter start time in seconds
      const startSeconds = Math.floor(chapter.positionMilliseconds / 1000);

      // Chapter end time: either next chapter start or video end
      let endSeconds: number;
      if (i + 1 < sortedChapters.length) {
        endSeconds = Math.floor(
          sortedChapters[i + 1].positionMilliseconds / 1000,
        );
      } else {
        endSeconds = videoLengthSeconds;
      }

      // Add to segments array
      const start = Math.max(0, startSeconds);
      const end = Math.min(videoLengthSeconds, endSeconds);
      if (Number.isFinite(start) && Number.isFinite(end) && end > start) {
        if (bazaarSegments.at(-1) === start) {
          bazaarSegments[bazaarSegments.length - 1] = end;
        } else bazaarSegments.push(start, end);
      }
    }
  }

  return bazaarSegments;
}
