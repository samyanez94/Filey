# Filey demo assets

These are real, locally bundled PDF and JPEG files. Seeding needs no external asset downloads. The
dataset includes 6 folders and 11 files, with an empty Inbox, nested folders, root files, a two-page
itinerary, and both portrait and landscape photos. Total size is about 5 MB.

## Seed

From the repository root:

    deno task seed

For the hosted project, using your existing private environment file:

    deno run --env-file=.env.hosted --allow-env --allow-net --allow-read=scripts/seed-assets scripts/seed-demo.ts

The script validates every file's byte count and SHA-256 before creating remote content. It uses
stable folder idempotency keys and upload IDs, so rerunning it skips ready uploads. It never deletes
existing content or user uploads. Legacy "Sample Files" fixtures are retained on existing projects;
fresh projects get only this dataset. Do not run the destructive reset script just to install these
fixtures.

The server treats uploaded content as immutable. When changing a fixture, update the manifest hash
and size and assign that file a new upload UUID. Keep folder keys stable. Pending uploads can be
resumed; cancelled or expired upload IDs require deliberate replacement.

## Documents

The seven PDFs were written for Filey. People, employers, merchants, purchases, and reservations are
fictional and clearly labeled. They contain selectable text, proper PDF structure, and page numbers.
The itinerary contains two pages.

To regenerate, install ReportLab and run python3 scripts/generate-seed-pdfs.py. Generation is
deterministic. Regeneration is optional; normal seeding uses the committed binaries.

## Photo credits

All four photographs were published under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) before Unsplash changed its license in
June 2017. Source pages document that original license. The files are bundled here for offline,
repeatable seeding.

| Local file        | Photographer   | Source                                                                                                  | Version                        |
| ----------------- | -------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------ |
| Mountain Hike.jpg | Micah H.       | [View from the mountain](https://commons.wikimedia.org/wiki/File:View_from_the_mountain_(Unsplash).jpg) | Original, 3072 x 2048          |
| Beach Sunset.jpg  | Avi Richards   | [Beach Sunset](https://commons.wikimedia.org/wiki/File:Beach_Sunset_(Unsplash).jpg)                     | Wikimedia 1280-pixel thumbnail |
| City Walk.jpg     | Pacific Austin | [Street-level view](https://commons.wikimedia.org/wiki/File:Street-level_view_(Unsplash).jpg)           | Original, portrait             |
| Desk Setup.jpg    | Luke Chesser   | [Desk Setup](https://commons.wikimedia.org/wiki/File:Desk_Setup_(Unsplash).jpg)                         | Original, 5184 x 3456          |

The user-facing names describe demo album entries, not the fictional travel itinerary's locations.
