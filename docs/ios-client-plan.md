# Filey iOS client implementation plan

Status: planned. Updated October 20, 2026.

## Goal and scope

Build a SwiftUI file-browser client for practicing iOS coding and system design interviews. Users automatically authenticate as the dedicated demo account, browse nested folders, create folders, import photos or PDFs, upload files with progress, preview files, and download files for offline access or export.

All installations share the demo account's remote content. The deployed backend supports this MVP without initial backend changes. Sharing, multi-user UI, rename/move, remote deletion, search, batch import, full offline synchronization, background transfers, and byte-range resumable transfers are outside the initial scope.

The current iOS project contains a placeholder screen. Its deployment target is iOS 27 with Swift 5 language mode. Before implementation, align the deployment target with the installed Xcode and intended devices, and enable Swift 6 concurrency checking.

## Architecture

Use feature-based folders, SwiftUI navigation, observable screen models, and a small set of injected services. Avoid adding layers that merely forward calls.

| Component | Responsibility |
| --- | --- |
| `SessionManager` | Restore the demo session, sign in, coordinate token refresh |
| `FileyAPIClient` | Typed HTTP requests, response decoding, application errors |
| `TransferManager` | Upload/download progress, cancellation, retry, recovery |
| `LocalFileStore` | Staged imports, transfer manifests, preview cache, saved downloads |
| Feature models | Screen state and user actions |

Views and observable screen models run on the main actor. Services own networking and file operations; views do not call Supabase directly. Isolate shared mutable transfer/session state and keep blocking file operations off the main actor. Inject service dependencies to support previews and deterministic tests.

Proposed feature areas are app startup, authentication, folder browsing, imports/transfers, and file preview/downloads. Place shared transport and storage infrastructure outside feature UI folders.

Recommended dependency: use the Supabase Swift SDK for authentication only, subject to approval before adding the dependency. Custom Filey API calls and file transfers use `URLSession` so their behavior remains explicit for interview practice. Configure Keychain-backed session persistence rather than assuming the SDK's default storage meets that requirement.

## Milestone 1: foundation and authentication

- Establish the app composition root, configuration, injected services, and typed API models.
- Keep local and hosted configuration separate. Only the project URL, public key, and dedicated demo credentials belong in client configuration; never include service-role or cleanup secrets.
- Restore a persisted session; otherwise sign in to the dedicated demo account without a login form.
- Store session credentials in Keychain. Demo credentials shipped in the app remain extractable and are suitable only for this shared sample account.
- Coordinate concurrent refresh requests so they share one refresh operation.
- On an API `401`, refresh and retry once. If the session cannot be recovered, attempt the demo sign-in through the coordinated session flow; avoid retry loops.
- Present startup loading and an actionable retry state when authentication is unavailable.
- Decode snake_case responses and handle application errors as well as non-JSON gateway failures.

Acceptance: launch the app, authenticate automatically, and retrieve the seeded root listing. Relaunch restores the session, and concurrent expired-token requests do not cause competing refreshes.

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

- Session restoration and simultaneous token refresh.
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

Authenticated application requests include `Authorization: Bearer <user-access-token>` and `apikey: <public-key>`. JSON requests include `Content-Type: application/json`. Signed Storage requests use the supplied URL and transfer headers without attaching the application session token. File bytes bypass the application API.

Supabase Auth provides password sign-in at `/auth/v1/token?grant_type=password` and refresh at `/auth/v1/token?grant_type=refresh_token`, relative to the hosted origin. The proposed SDK integration owns these calls and session handling.

The client never calls the server-only cleanup function or writes application tables directly. Public signup is disabled. Backend errors include a machine-readable code, retryability, and request ID; gateway failures may have a different body.

## Implementation order

1. Launch → demo authentication → browse seeded folders.
2. Folder navigation, pagination, and creation.
3. Import → signed upload → finalization, with transfer progress.
4. Signed download → local preview → persistent download/export.
5. Recovery, focused tests, accessibility, and device verification.

Each milestone should produce an independently testable increment. No client implementation or dependency installation is included in this planning document.

## Platform references

- [Supabase Swift SDK](https://github.com/supabase/supabase-swift)
- [Supabase session refresh](https://supabase.com/docs/reference/swift/auth-refreshsession)
- [SwiftUI file importer](https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:oncompletion:))
- [URLSession file-backed uploads](https://developer.apple.com/documentation/foundation/urlsession/upload(for:fromfile:))
