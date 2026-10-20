# Filey iOS client implementation plan

Status: planned. Updated October 20, 2026.

## Goal and scope

Build a SwiftUI file-browser client for practicing iOS coding and system design interviews. Users access one shared demo workspace with a configured API key, browse nested folders, create folders, import photos or PDFs, upload files with progress, preview files, and download files for offline access or export.

All installations share the demo account's remote content. The deployed backend supports this MVP without initial backend changes. Sharing, multi-user UI, rename/move, remote deletion, search, batch import, full offline synchronization, background transfers, and byte-range resumable transfers are outside the initial scope.

The current iOS project contains a placeholder screen. Its deployment target is iOS 27 with Swift 5 language mode. Before implementation, align the deployment target with the installed Xcode and intended devices, and enable Swift 6 concurrency checking.

## Architecture

Use feature-based folders, SwiftUI navigation, observable screen models, and a small set of injected services. Avoid adding layers that merely forward calls.

| Component | Responsibility |
| --- | --- |
| `FileyAPIClient` | Typed HTTP requests, response decoding, application errors |
| `TransferManager` | Upload/download progress, cancellation, retry, recovery |
| `LocalFileStore` | Staged imports, transfer manifests, preview cache, saved downloads |
| Feature models | Screen state and user actions |

Views and observable screen models run on the main actor. Services own networking and file operations; views do not call Supabase directly. Isolate shared mutable transfer state and keep blocking file operations off the main actor. Inject service dependencies to support previews and deterministic tests.

Proposed feature areas are app startup, configuration, folder browsing, imports/transfers, and file preview/downloads. Place shared transport and storage infrastructure outside feature UI folders.

Use Foundation `URLSession` for both Filey API calls and signed file transfers. No Supabase Swift SDK, login screen, session persistence, access token, or refresh-token handling is required.

## Milestone 1: foundation and API access

- Establish the app composition root, configuration, injected services, and typed API models.
- `AppConfiguration.apiBaseURL` defines the application API base URL. Following Chirpy, `AppConfiguration.apiKey` reads `FileyAPIKey` from the bundled, Git-ignored `Filey/LocalConfiguration.plist`. Copy `Configuration/LocalConfiguration.example.plist` there for a fresh checkout and replace its placeholder. Missing or malformed plist files, or a missing `FileyAPIKey` entry, return `nil`. The client should also reject empty or placeholder key values before making requests. Use the backend's `FILEY_API_KEY` value for that environment. For hosted development, copy only `FILEY_API_KEY` from `.env.hosted` and derive the API base URL by appending `/functions/v1/api/v1` to `SUPABASE_URL`. The remaining variables are operator-only; do not bundle `.env.hosted` with the app.
- Add `X-Filey-API-Key` to every application API request. Do not send it to signed Storage URLs or arbitrary hosts.
- Never include Supabase service-role keys, cleanup secrets, or demo account passwords in the app. A Supabase public key is not needed for the application routes.
- A shared key shipped in the app is extractable and grants access to disposable demo content; it is not individual user authentication.
- On `401`, show a configuration/access error. Do not attempt token refresh or repeatedly retry the same invalid key. After rotation, update the local app key and rebuild.
- Decode snake_case responses and handle application errors as well as non-JSON gateway failures.

Acceptance: launch the app and retrieve the seeded root listing using only the shared API key. Missing or incorrect keys produce a recoverable access-error screen; no session bootstrap is involved.

## Milestone 2: folder browsing and creation

Build one reusable folder screen inside a `NavigationStack`.

- Browse root and nested folders with folder/file icons, filenames, and file sizes.
- Support loading, empty, error, retry, and pull-to-refresh states.
- Fetch cursor-based pages and deduplicate items by UUID. Pagination is not a snapshot, so refresh resets the cursor and listing.
- Cancel stale requests when navigating and guard against late responses replacing the current folder's state.
- Add a create-folder sheet. Generate one idempotency key for each logical creation attempt and preserve its payload and key across retries.
- Refresh the affected folder after successful creation.

Acceptance: users navigate the seeded hierarchy, create folders, refresh, and load additional pages without duplicate rows or stale navigation results.

## Milestone 3: imports and uploads

Use the system photo picker and Files importer. Initially select one file at a time, with a small bounded transfer queue.

1. Copy selected content into app-owned staging storage. For security-scoped URLs, acquire access while copying and release it afterward. Handle provider/iCloud loading failures.
2. Determine the staged representation's actual MIME type and byte count; do not infer them solely from the filename. If conversion is needed, finish it before establishing upload metadata.
3. Validate JPEG, PNG, HEIC, HEIF, or PDF and the **20,000,000-byte** maximum.
4. Generate and persist a file UUID, destination folder, immutable upload metadata, and staged file location.
5. Call `PUT /uploads/{fileID}` with the metadata.
6. If pending, upload raw file bytes to the returned signed URL using its method and headers. Use a file-backed `URLSession` upload rather than buffering the entire file in memory.
7. Call `POST /uploads/{fileID}/complete` to verify and publish the file.
8. Refresh the destination folder and release staging data when recovery no longer needs it.

Display `Preparing → Queued → Uploading → Finalizing → Completed`, plus failed, retrying, and cancelling states. A transfer at 100% remains “Finalizing” until the backend confirms readiness. Pending uploads appear in transfer UI, not as ready files in folder listings.

### Recovery and cancellation

- Preserve the same file UUID and metadata across retries.
- After an ambiguous failure, query upload status before transferring again. A repeated begin request can verify bytes already stored and return a ready file.
- Obtain a new upload target through begin when needed; a status request alone does not issue one.
- Treat signed URLs as temporary capabilities, not durable file identifiers.
- Cancellation stops the local task and requests server cancellation. If that request cannot reach the server, retain the cancellation intent for reconciliation.
- If completion wins the cancellation race, show the completed file. Existing signed URLs can remain valid after cancellation; server cleanup is asynchronous.
- Cancelled or expired uploads require a new UUID for a new attempt.
- Persist a small transfer manifest and staged files so interrupted work can be reconciled after relaunch. Handle missing local files explicitly.
- MVP transfers run in the foreground. Relaunch recovery does not imply background execution or resumption from a byte offset.

Acceptance: a photo and PDF upload successfully, show progress, become visible after finalization, and recover from lost responses without duplicate remote files. Cancellation and relaunch recovery have explicit outcomes.

## Milestone 4: preview and download

Tapping a file downloads it into a local preview cache and opens a system Quick Look preview.

- Request a signed download URL when needed and download to disk with progress and cancellation.
- Cache by file UUID; remote file contents are immutable.
- Obtain a fresh URL after expiry and retry within a bounded policy.
- Verify downloaded byte count before presenting or retaining the file; byte count is not a content-integrity checksum.
- Separate evictable preview cache from explicitly saved downloads.
- Provide “Download” for persistent app-local storage and “Save to Files” for export.
- Allow previously downloaded files to open offline; full offline folder browsing and synchronization are deferred.
- Coalesce duplicate requests for the same file where practical.
- Use generic file icons initially. Thumbnail generation and sophisticated cache eviction can follow later.

Acceptance: seeded and newly uploaded photos/PDFs preview successfully, export to Files, and explicitly downloaded files remain available after relaunch and without a network connection.

## Milestone 5: reliability, testing, and polish

Use injected services and mocked HTTP responses for deterministic tests. Focus on meaningful failure modes:

- Shared-key header injection, missing/invalid-key handling, and ensuring credentials are not sent to signed Storage URLs.
- Pagination, duplicate results, and stale navigation responses.
- Folder creation retries without duplicate resources.
- Upload interruptions before and after bytes reach Storage.
- Lost completion responses and cancellation races.
- Expired signed download URLs.
- Relaunch recovery and missing staged files.
- Non-JSON gateway failures, rate limits, and offline errors.

Retry transient failures with bounded backoff and respect `Retry-After`. Do not automatically retry validation errors. Retry mutations only with their stable identifiers/idempotency keys and appropriate state reconciliation. Log backend request IDs for diagnosis without logging credentials or signed URLs.

Run simulator and device checks for photo/PDF imports, provider-backed Files imports, preview, export, transfer interruption, Dynamic Type, and VoiceOver. Hosted smoke checks should use deliberate sample content; the backend's automated integration suite intentionally rejects non-local targets.

Acceptance: the main workflow and recovery cases pass automated checks, and the import/preview/export workflow works on a device with accessible loading, progress, and error states.

## Backend integration contract

Hosted origin: `https://bgcdtyjffxtcrciyfewp.supabase.co`

Application API base: `https://bgcdtyjffxtcrciyfewp.supabase.co/functions/v1/api/v1`

The [OpenAPI specification](openapi.yaml) is the detailed HTTP contract. The [Backend wiki](https://github.com/samyanez94/Filey/wiki/Backend) documents authentication, deployment, upload semantics, and cleanup.

| Client action | Method and path relative to API base |
| --- | --- |
| Browse root/folder | `GET /items` with optional `parent_id`, `cursor`, and `limit` |
| Create folder | `POST /folders` with `Idempotency-Key` |
| Fetch folder metadata | `GET /folders/{id}` |
| Fetch ready file metadata | `GET /files/{id}` |
| Start/recover upload | `PUT /uploads/{id}` |
| Inspect upload | `GET /uploads/{id}` |
| Finalize upload | `POST /uploads/{id}/complete` |
| Cancel upload | `DELETE /uploads/{id}` |
| Request download URL | `POST /files/{id}/download-url` |

Application requests include `X-Filey-API-Key: <shared-demo-key>`. JSON requests include `Content-Type: application/json`. Signed Storage requests use only the supplied URL and transfer headers, without the Filey key. File bytes bypass the application API.

The backend validates the key and selects `DEMO_USER_ID` itself; callers cannot select an owner. The client never calls Supabase Auth, the server-only cleanup function, or application tables directly. Public signup and direct anonymous/authenticated table access are disabled. Backend errors include a machine-readable code, retryability, and request ID; gateway failures may have a different body.

## Implementation order

1. Launch → configured API client → browse seeded folders.
2. Folder navigation, pagination, and creation.
3. Import → signed upload → finalization, with transfer progress.
4. Signed download → local preview → persistent download/export.
5. Recovery, focused tests, accessibility, and device verification.

Each milestone should produce an independently testable increment. No client implementation or dependency installation is included in this planning document.

## Platform references

- [SwiftUI file importer](https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:oncompletion:))
- [URLSession file-backed uploads](https://developer.apple.com/documentation/foundation/urlsession/upload(for:fromfile:))
