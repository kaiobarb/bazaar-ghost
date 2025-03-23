"use client";

import type React from "react";

import { useState } from "react";
import { Search } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

export default function StreamerSearch() {
  const [username, setUsername] = useState("");
  const [selectedStreamer, setSelectedStreamer] = useState("");

  const handleSearch = (e: React.FormEvent) => {
    e.preventDefault();
    console.log("Searching for:", { streamer: selectedStreamer, username });
    // Here you would implement the actual search functionality
  };

  return (
    <div className="rounded-xl bg-zinc-800/50 p-6 shadow-lg">
      <form
        onSubmit={handleSearch}
        className="space-y-4 space-x-4 flex flex-wrap"
      >
        <div className="space-y-2 flex-3">
          <label
            htmlFor="streamer"
            className="block text-left text-sm font-medium text-zinc-300"
          >
            Select Streamer
          </label>
          <Select value={selectedStreamer} onValueChange={setSelectedStreamer}>
            <SelectTrigger className="h-12 border-zinc-700 bg-zinc-900 text-white w-full">
              <SelectValue
                placeholder="Choose a streamer"
                defaultValue="nl_kripp"
              />
            </SelectTrigger>
            <SelectContent className="border-zinc-700 bg-zinc-900 text-white">
              <SelectItem value="nl_kripp">Kripp</SelectItem>
            </SelectContent>
          </Select>
        </div>

        <div className="space-y-2 flex-9">
          <label
            htmlFor="username"
            className="block text-left text-sm font-medium text-zinc-300"
          >
            Enter Username
          </label>
          <div className="relative">
            <Input
              id="username"
              type="text"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              placeholder="Enter the username of the player you want to find clips against"
              className="border-zinc-700 bg-zinc-900 pl-10 text-white placeholder:text-zinc-500"
            />
            <Search className="absolute left-3 top-1/2 h-5 w-5 -translate-y-1/2 text-zinc-500" />
          </div>
          {/* <p className="text-left text-xs text-zinc-500">
            Enter the username of the player you want to find clips against
          </p> */}
        </div>

        <Button
          type="submit"
          className="h-12 bg-purple-600 text-lg font-medium hover:bg-purple-700 w-full"
        >
          Search Clips
        </Button>
      </form>
    </div>
  );
}
