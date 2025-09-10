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
  console.log(`Client ID: ${TWITCH_CLIENT_ID}`);
  console.log(`Token: ${token.substring(0, 10)}...`);

  // Log full headers for debugging
  const headers = {
    "Client-Id": TWITCH_CLIENT_ID,
    Authorization: `Bearer ${token}`,
    Accept: "application/json",
    "accept-language": "PURPOSELYBADVALUEBECAUSETWITCHAPIISGARBAGE",
    "User-Agent": "Bazaar-Ghost-Cataloger/1.0",
  };
  console.log(`Request headers:`, JSON.stringify(headers, null, 2));

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

  // First get the response as text to debug
  const responseText = await response.text();

  // Log raw response for videos endpoint
  if (endpoint === "videos") {
    console.log(
      `Videos API Raw Response (first 500 chars):`,
      responseText.substring(0, 500)
    );
  }

  // Parse JSON
  let responseData;
  try {
    responseData = JSON.parse(responseText);
  } catch (e) {
    console.error("Failed to parse JSON response:", e);
    console.error("Raw response:", responseText);
    throw new Error("Invalid JSON response from Twitch API");
  }

  // Log the full response for videos endpoint
  if (endpoint === "videos") {
    console.log(`Videos API Response:`, JSON.stringify(responseData, null, 2));
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