const TWITCH_CLIENT_ID = Deno.env.get("TWITCH_CLIENT_ID")!;
const TWITCH_CLIENT_SECRET = Deno.env.get("TWITCH_CLIENT_SECRET")!;

interface TwitchToken {
  access_token: string;
  expires_at: number;
}

let twitchToken: TwitchToken | null = null;

export async function getTwitchToken(): Promise<string> {
  if (twitchToken && twitchToken.expires_at > Date.now()) {
    return twitchToken.access_token;
  }

  console.log("Generating new Twitch token...");
  const response = await fetch("https://id.twitch.tv/oauth2/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: TWITCH_CLIENT_ID,
      client_secret: TWITCH_CLIENT_SECRET,
      grant_type: "client_credentials",
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error("Failed to get Twitch token:", errorText);
    throw new Error(`Failed to get Twitch token: ${response.status}`);
  }

  const data = await response.json();
  console.log("Token generated successfully, expires in:", data.expires_in);

  twitchToken = {
    access_token: data.access_token,
    expires_at: Date.now() + data.expires_in * 1000 - 60000, // Refresh 1 min early
  };

  return twitchToken.access_token;
}

export async function twitchApiCall(
  endpoint: string,
  params?: Record<string, string>
) {
  const token = await getTwitchToken();
  const url = new URL(`https://api.twitch.tv/helix/${endpoint}`);

  if (params) {
    Object.entries(params).forEach(([key, value]) => {
      url.searchParams.append(key, value);
    });
  }

  console.log(`Twitch API call to: ${url.toString()}`);

  const headers = {
    "Client-Id": TWITCH_CLIENT_ID,
    Authorization: `Bearer ${token}`,
    Accept: "application/json",
    "accept-language": "PURPOSELYBADVALUEBECAUSETWITCHAPIISGARBAGE",
    "User-Agent": "Bazaar-Ghost-Update-VODs/1.0",
  };

  const response = await fetch(url.toString(), {
    method: "GET",
    headers: headers,
  });

  console.log(`Response status: ${response.status}`);
  if (!response.ok) {
    const errorText = await response.text();
    console.log(`Error response: ${errorText}`);
    throw new Error(
      `Twitch API error: ${response.status} ${response.statusText}`
    );
  }

  const responseText = await response.text();

  let responseData;
  try {
    responseData = JSON.parse(responseText);
  } catch (e) {
    console.error("Failed to parse JSON response:", e);
    console.error("Raw response:", responseText);
    throw new Error("Invalid JSON response from Twitch API");
  }

  return responseData;
}

export async function getBazaarGameId(): Promise<string> {
  const { data } = await twitchApiCall("search/categories", {
    query: "The Bazaar",
    first: "10",
  });

  // Find exact match for "The Bazaar"
  const bazaarGame = data?.find(
    (game: any) => game.name.toLowerCase() === "the bazaar"
  );

  if (!bazaarGame) {
    console.log(
      "Available games found:",
      data?.map((g: any) => g.name)
    );
    throw new Error("The Bazaar game not found on Twitch");
  }

  console.log(`Found The Bazaar with ID: ${bazaarGame.id}`);
  return bazaarGame.id;
}

export async function checkVodAvailability(vodId: string): Promise<boolean> {
  try {
    const { data } = await twitchApiCall("videos", {
      id: vodId,
    });

    // If we get data back with the VOD, it's available
    return data && data.length > 0;
  } catch (error) {
    // If API call fails (404, etc.), VOD is not available
    console.log(`VOD ${vodId} is not available: ${error.message}`);
    return false;
  }
}

export async function batchCheckVodAvailability(
  vodIds: string[]
): Promise<Record<string, boolean>> {
  const results: Record<string, boolean> = {};

  // Twitch API can handle up to 100 video IDs in a single call
  const batchSize = 100;

  for (let i = 0; i < vodIds.length; i += batchSize) {
    const batch = vodIds.slice(i, i + batchSize);

    try {
      const { data } = await twitchApiCall("videos", {
        id: batch.join(","),
      });

      // Mark all requested VODs as unavailable by default
      for (const vodId of batch) {
        results[vodId] = false;
      }

      // Mark returned VODs as available
      if (data) {
        for (const vod of data) {
          results[vod.id] = true;
        }
      }

      console.log(`Checked availability for ${batch.length} VODs`);

      // Rate limiting: wait 1 second between batches
      if (i + batchSize < vodIds.length) {
        await new Promise((resolve) => setTimeout(resolve, 1000));
      }
    } catch (error) {
      console.error(`Error checking VOD availability for batch:`, error);
      // Mark all VODs in this batch as unavailable
      for (const vodId of batch) {
        results[vodId] = false;
      }
    }
  }

  return results;
}
