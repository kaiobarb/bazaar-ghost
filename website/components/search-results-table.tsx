"use client";

import { useState } from "react";
import { ChevronDown, ChevronUp, ExternalLink } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { TablePagination } from "./table-pagination";
import { useSearchParams, usePathname } from "next/navigation";
import { useRouter } from "next/navigation";
import Image from "next/image";

interface SearchResultsTableProps {
  results: {
    id: number;
    vod_id: number | null;
    username: string;
    vod_link: string;
    rank: string | null;
    frame_time: number;
    vods: {
      streamer_id: number | null;
      streamers: {
        name: string;
        display_name: string | null;
        profile_image_url: string | null;
      } | null;
    } | null;
  }[];
  pageData: {
    total: number;
    page: number;
    pageSize: number;
    totalPages: number;
  };
}

export default function SearchResultsTable({
  results,
  pageData,
}: SearchResultsTableProps) {
  const [expandedRows, setExpandedRows] = useState<Record<string, boolean>>({});

  const toggleRow = (id: number) => {
    setExpandedRows((prev) => ({
      ...prev,
      [id]: !prev[id],
    }));
  };

  const searchParams = useSearchParams();
  const pathname = usePathname();
  const { replace } = useRouter();

  const page = Number(searchParams.get("p")) || pageData.page;
  const pageSize = Number(searchParams.get("ps")) || pageData.pageSize;
  const totalPages = Number(searchParams.get("tp")) || pageData.totalPages;
  const total = Number(searchParams.get("t")) || pageData.total;

  const handlePageChange = (page: number) => {
    console.log(page);
    const params = new URLSearchParams(searchParams);
    if (page) {
      params.set("p", page.toString());
    } else {
      params.delete("p");
    }
    replace(`${pathname}?${params.toString()}`, { scroll: false });
  };

  // Calculate pagination
  // const startIndex = (currentPage - 1) * pageData.pageSize;
  // const endIndex = Math.min(startIndex + pageData.pageSize, results.length);

  // Handle page size change
  const handlePageSizeChange = (size: number) => {
    const params = new URLSearchParams(searchParams);
    if (size) {
      params.set("ps", size.toString());
    } else {
      params.delete("ps");
    }
    replace(`${pathname}?${params.toString()}`, { scroll: false });
    // handlePageChange(1);
    setExpandedRows({}); // Reset expanded rows
  };

  if (results.length === 0) {
    return (
      <div className="mt-8 rounded-lg border border-zinc-800 bg-zinc-900 p-8 text-center">
        <p className="text-zinc-400">
          No results found. Try adjusting your search criteria.
        </p>
      </div>
    );
  }

  return (
    <div className="mt-8 overflow-hidden rounded-lg border border-zinc-800">
      <Table>
        <TableHeader className="bg-zinc-900">
          <TableRow className="hover:bg-zinc-900/90 border-zinc-800">
            <TableHead className="text-zinc-400 w-[250px]">Stream</TableHead>
            <TableHead className="text-zinc-400">Username</TableHead>
            <TableHead className="text-zinc-400">Date</TableHead>
            <TableHead className="text-zinc-400 text-right">Actions</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {results.map((result) => (
            <>
              <TableRow
                key={result.id}
                className="cursor-pointer border-zinc-800 bg-zinc-900/50 hover:bg-zinc-800/50"
                onClick={() => toggleRow(result.id)}
              >
                {/* Stream */}
                <TableCell className="font-medium">
                  <div className="flex items-center gap-3">
                    <Avatar className="h-10 w-10 border border-zinc-700">
                      <AvatarImage
                        src={
                          result.vods?.streamers?.profile_image_url || undefined
                        }
                        alt={result.vods?.streamers?.name}
                      />
                      <AvatarFallback>
                        {result.vods?.streamers?.display_name
                          ?.substring(0, 2)
                          .toUpperCase() ||
                          result.vods?.streamers?.name
                            ?.substring(0, 2)
                            .toUpperCase() ||
                          "ST"}
                      </AvatarFallback>
                    </Avatar>
                    <div className="font-medium">
                      {result.vods?.streamers?.display_name ||
                        result.vods?.streamers?.name}
                    </div>
                  </div>
                </TableCell>

                {/* Username */}
                <TableCell className="flex flex-row items-center gap-4">
                  <Image
                    src={`/${result.rank}_32.png`}
                    alt={`${result.rank}`}
                    width={36}
                    height={36}
                  />
                  {result.username}
                </TableCell>

                {/* Date - Currently empty in the original */}
                <TableCell className="text-zinc-400">
                  {/* Date would go here */}
                </TableCell>

                {/* Actions */}
                <TableCell className="text-right">
                  <div className="flex items-center justify-end gap-2">
                    <a
                      href={result.vod_link}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="flex items-center gap-1 rounded bg-purple-600 px-3 py-1.5 text-sm font-medium hover:bg-purple-700"
                      onClick={(e) => e.stopPropagation()}
                    >
                      <ExternalLink className="h-4 w-4" />
                      <span className="hidden sm:inline">Twitch</span>
                    </a>
                    <Button
                      variant="ghost"
                      size="icon"
                      className="ml-2 h-8 w-8 rounded-full"
                      onClick={(e) => {
                        e.stopPropagation();
                        toggleRow(result.id);
                      }}
                    >
                      {expandedRows[result.id] ? (
                        <ChevronUp className="h-5 w-5" />
                      ) : (
                        <ChevronDown className="h-5 w-5" />
                      )}
                    </Button>
                  </div>
                </TableCell>
              </TableRow>

              {/* Expanded Content */}
              {expandedRows[result.id] && (
                <TableRow className="border-0 hover:bg-zinc-800/50">
                  <TableCell
                    colSpan={4}
                    className="p-0 border-t border-zinc-800"
                  >
                    <div className="bg-zinc-900/30 p-4">
                      <div className="aspect-video w-full overflow-hidden rounded-lg">
                        <iframe
                          src={`https://player.twitch.tv/?video=${
                            result.vod_id
                          }&parent=localhost&time=${
                            result.frame_time - 1
                          }&autoplay=false&muted=true`}
                          height="100%"
                          width="100%"
                          allowFullScreen={true}
                          className="h-full w-full"
                        ></iframe>
                      </div>
                      <div className="mt-3 text-sm text-zinc-400">
                        <p>
                          {result.vods?.streamers?.name} vs {result.username}
                        </p>
                      </div>
                    </div>
                  </TableCell>
                </TableRow>
              )}
            </>
          ))}
        </TableBody>
      </Table>
      {/* Pagination */}
      <div className="border-t border-zinc-800 bg-zinc-900 px-4 py-2">
        <TablePagination
          currentPage={page}
          totalPages={totalPages}
          pageSize={pageSize}
          totalItems={total}
          onPageChange={handlePageChange}
          onPageSizeChange={handlePageSizeChange}
        />
      </div>
    </div>
  );
}
