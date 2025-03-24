import Image from "next/image";
import StreamerSearch from "@/components/streamer-search";
import SearchResultsTable from "@/components/search-results-table";
import { fetchMatchups } from "./data";

export default async function Home(props: {
  searchParams?: Promise<{
    username?: string;
    page?: string;
    stream?: string;
  }>;
}) {
  const searchParams = await props.searchParams;
  const username = searchParams?.username || "";
  const stream = searchParams?.stream || undefined;

  const matchups = await fetchMatchups(username, stream);
  console.log(matchups);
  return (
    <div className="min-h-screen bg-[#0e0e10] text-white">
      {/* Header */}
      <header className="border-b border-zinc-800 bg-[#18181b] py-3">
        <div className="container mx-auto flex items-center justify-between px-4">
          <div className="flex items-center gap-2">
            <Image
              src="/placeholder.svg?height=32&width=32"
              width={32}
              height={32}
              alt="Bazaar Ghost"
              className="rounded"
            />
            <h1 className="text-xl font-bold">BazaarGhost</h1>
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="container mx-auto px-4 py-12">
        <div className="mx-auto max-w-3xl text-center h-full">
          <h2 className="mb-6 text-4xl font-bold">
            Find Bazaar Ghost Matchups
          </h2>
          <p className="mb-8 text-lg text-zinc-400">
            Search for matchups between streamers and ghosts of other players
          </p>

          {/* Search Component */}
          <StreamerSearch />

          <SearchResultsTable results={matchups} />
        </div>
      </main>

      {/* Footer */}
      <footer className="border-t border-zinc-800 bg-[#18181b] py-6">
        <div className="container mx-auto px-4 text-center text-zinc-400">
          <p>© 2025 BazaarGhost. Not affiliated with Twitch or The Bazaar.</p>
        </div>
      </footer>
    </div>
  );
}
