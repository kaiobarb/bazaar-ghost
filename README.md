Overview

This project is Bazaar Ghost, a system that indexes Twitch VODs for the game The Bazaar, detects matchup screens, extracts usernames, and makes them searchable.

SFOT = Streamlink → FFmpeg → OpenCV → Tesseract.

SFOT is the pipeline for detecting matchup frames and OCR’ing usernames.

Target platform is Twitch only for now. YouTube support comes later.

See DESIGN_DOC.md for high-level architecture, flows, and system responsibilities.

Scope & Style

Not opinionated: this document does not prescribe exact implementations. Some ambiguities will be resolved incrementally.

Schema-first: database schema definition is the first concrete work item.

Treat any DB mentions in DESIGN_DOC.md as pseudocode only.

Ignore implicit/assumed columns from design doc; schema will be authored here explicitly.

Repo Layout

/home/kaio/Dev/bazaar-ghost

Second iteration, intended to be more polished.

/home/kaio/Dev/krippTrack (first iteration, PoC)

website/ → Next.js frontend (low priority in 2nd iteration).

supabase/ → CLI artifacts, ignorable.

bazaar-ghost/ → Old bash/python SFOT scripts (PoC), some downloaded vods, and lots frames created and used to test, debug, and develop the PoC.
Can be referenced, but do not reference it an authoritative implementation example.

Rules

Use DESIGN_DOC.md for architecture guidance only.

Ignore references in DESIGN_DOC.md to DB columns or schema; treat them as illustrative pseudocode.

Focus development work in /home/kaio/Dev/bazaar-ghost.

First milestone: define schema in Supabase/Postgres.

Notes

Long-term vision includes YouTube ingestion, but only Twitch should be implemented in this phase.

Human-in-the-loop vetting is required before backfilling VODs (streamer profile verification, ROI not blocked, etc.).

SFOT work must remain containerized for runtime parity across local/VM/Cloud Run.
