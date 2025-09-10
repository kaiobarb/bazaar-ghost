import { getBazaarGameId } from "../lib/twitch.ts";
import { discoverStreamers } from "./discover-streamers.ts";

export async function fullRun() {
  const gameId = await getBazaarGameId();
  const streamers = await discoverStreamers(gameId);
  return { streamers };
}