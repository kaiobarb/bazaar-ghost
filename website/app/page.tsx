import Image from "next/image";
import StreamerSearch from "@/components/streamer-search";

export default function Home() {
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
          <div className="flex items-center gap-4">
            <button className="rounded bg-purple-600 px-4 py-1.5 font-medium hover:bg-purple-700">
              Log in
            </button>
            <button className="rounded bg-zinc-700 px-4 py-1.5 font-medium hover:bg-zinc-600">
              Sign Up
            </button>
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="container mx-auto px-4 py-12">
        <div className="mx-auto max-w-3xl text-center">
          <h2 className="mb-6 text-4xl font-bold">
            Find Bazaar Gameplay Clips
          </h2>
          <p className="mb-8 text-lg text-zinc-400">
            Search for Twitch clips where streamers played against you or other
            players in The Bazaar
          </p>

          {/* Search Component */}
          <StreamerSearch />

          {/* Featured Clips */}
          {/* <div className="mt-16">
            <h3 className="mb-6 text-left text-2xl font-bold">
              Featured Clips
            </h3>
            <div className="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3">
              {[1, 2, 3].map((item) => (
                <div
                  key={item}
                  className="overflow-hidden rounded-lg bg-zinc-800"
                >
                  <div className="relative aspect-video bg-zinc-900">
                    <div className="absolute bottom-2 left-2 rounded bg-red-600 px-1.5 py-0.5 text-xs font-medium">
                      LIVE
                    </div>
                    <Image
                      src="/placeholder.svg?height=180&width=320"
                      width={320}
                      height={180}
                      alt="Stream thumbnail"
                      className="h-full w-full object-cover"
                    />
                  </div>
                  <div className="p-3">
                    <div className="flex gap-2">
                      <Image
                        src="/placeholder.svg?height=40&width=40"
                        width={40}
                        height={40}
                        alt="Streamer avatar"
                        className="h-10 w-10 rounded-full"
                      />
                      <div>
                        <h4 className="font-medium">
                          Epic Bazaar Match vs xPlayer123
                        </h4>
                        <p className="text-sm text-zinc-400">StreamerName</p>
                        <p className="text-xs text-zinc-500">
                          2.5K views • 3 hours ago
                        </p>
                      </div>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div> */}

          {/* Popular Streamers */}
          {/* <div className="mt-12">
            <h3 className="mb-6 text-left text-2xl font-bold">
              Popular Bazaar Streamers
            </h3>
            <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5">
              {[1, 2, 3, 4, 5].map((item) => (
                <div key={item} className="text-center">
                  <div className="mx-auto mb-2 h-16 w-16 overflow-hidden rounded-full">
                    <Image
                      src="/placeholder.svg?height=64&width=64"
                      width={64}
                      height={64}
                      alt="Streamer avatar"
                      className="h-full w-full object-cover"
                    />
                  </div>
                  <h4 className="font-medium">Streamer{item}</h4>
                  <p className="text-xs text-zinc-400">12.5K followers</p>
                </div>
              ))}
            </div>
          </div> */}
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
