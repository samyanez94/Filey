import Foundation
import Testing

@testable import Filey

// MARK: - FolderViewModelTests

@MainActor
struct FolderViewModelTests {
	@Test(arguments: [nil, UUID()] as [UUID?])
	func loadsSelectedFolder(parentID: UUID?) async {
		let item = FileItem(id: UUID(), kind: .folder, name: "Photos", byteCount: nil)
		let service = MockService { requestedID in
			#expect(requestedID == parentID)
			return ItemsPage(items: [item], nextCursor: "next-page")
		}
		let model = FolderViewModel(folder: FolderLocation(id: parentID, name: "Files"), service: service)

		await model.load()

		guard case .loaded(let page) = model.state else {
			Issue.record("Expected a loaded folder")
			return
		}
		#expect(page.items.map(\.id) == [item.id])
		#expect(page.nextCursor == "next-page")
	}

	@Test func returningToLoadedFolderDoesNotFetchAgain() async {
		let service = MockService { _ in ItemsPage(items: [], nextCursor: nil) }
		let model = FolderViewModel(folder: .root, service: service)

		await model.loadIfNeeded()
		await model.loadIfNeeded()

		#expect(service.requestCount == 1)
		guard case .loaded = model.state else {
			Issue.record("Expected the loaded folder to stay visible")
			return
		}

		await model.load()
		#expect(service.requestCount == 2)
	}

	@Test func cancelledInitialLoadCanRestart() async {
		let service = MockService { _ in throw CancellationError() }
		let model = FolderViewModel(folder: .root, service: service)

		await model.loadIfNeeded()
		service.handler = { _ in ItemsPage(items: [], nextCursor: nil) }
		await model.loadIfNeeded()

		#expect(service.requestCount == 2)
		guard case .loaded = model.state else {
			Issue.record("Expected the cancelled load to restart")
			return
		}
	}

	@Test func previewSuccessKeepsFolderAndCleansUpOnDismissal() async throws {
		let file = FileItem(id: UUID(), kind: .file, name: "Notes.pdf", byteCount: 3)
		let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try Data("PDF".utf8).write(to: localURL)
		defer { try? FileManager.default.removeItem(at: localURL) }
		let service = MockService { _ in ItemsPage(items: [file], nextCursor: nil) }
		service.downloadHandler = { id in
			#expect(id == file.id)
			return DownloadTarget(url: localURL, contentType: "application/pdf", byteCount: 3)
		}
		let model = FolderViewModel(
			folder: .root,
			service: service,
			previewDownloader: MockPreviewDownloader { target in
				#expect(target.contentType == "application/pdf")
				return localURL
			}
		)
		await model.load()
		model.selectedFile = file

		await model.preparePreview(for: file)

		#expect(model.selectedFile == nil)
		#expect(model.previewURL == localURL)
		#expect(!model.showsPreviewError)
		guard case .loaded = model.state else {
			Issue.record("Previewing should leave the folder loaded")
			return
		}
		model.previewURL = nil
		#expect(!FileManager.default.fileExists(atPath: localURL.path))
	}

	@Test func previewFailureClearsSelectionAndShowsError() async {
		let service = MockService { _ in ItemsPage(items: [], nextCursor: nil) }
		service.downloadHandler = { _ in throw APIError.unauthorized }
		let model = FolderViewModel(folder: .root, service: service)
		let file = FileItem(id: UUID(), kind: .file, name: "Notes.pdf", byteCount: 3)
		model.selectedFile = file

		await model.preparePreview(for: file)

		#expect(model.selectedFile == nil)
		#expect(model.previewURL == nil)
		#expect(model.showsPreviewError)
		#expect(model.previewErrorMessage == APIError.unauthorized.localizedDescription)
	}

	@Test func previewCancellationClearsSelectionWithoutShowingError() async throws {
		let url = try #require(URL(string: "https://storage.example.test/file"))
		let service = MockService { _ in ItemsPage(items: [], nextCursor: nil) }
		service.downloadHandler = { _ in
			DownloadTarget(url: url, contentType: "application/pdf", byteCount: 3)
		}
		let model = FolderViewModel(
			folder: .root,
			service: service,
			previewDownloader: MockPreviewDownloader { _ in throw URLError(.cancelled) }
		)
		let file = FileItem(id: UUID(), kind: .file, name: "Notes.pdf", byteCount: 3)
		model.selectedFile = file

		await model.preparePreview(for: file)

		#expect(model.selectedFile == nil)
		#expect(model.previewURL == nil)
		#expect(!model.showsPreviewError)
	}

	@Test func preparationFailureShowsErrorWithoutUploading() async throws {
		let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
		try Data().write(to: source)
		defer { try? FileManager.default.removeItem(at: source) }
		let service = MockService { _ in ItemsPage(items: [], nextCursor: nil) }
		service.uploadHandler = { _ in
			Issue.record("A file that failed preparation should not upload")
			throw URLError(.badURL)
		}
		let model = FolderViewModel(folder: .root, service: service)

		await model.importPDF(from: source)

		#expect(!model.isUploading)
		#expect(model.pendingUpload == nil)
		#expect(model.showsUploadError)
		#expect(model.uploadErrorMessage == FileImportError.invalidSize.localizedDescription)
		#expect(service.requestCount == 0)
	}

	@Test func failedUploadRetainsFileAndRetryCleansUp() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let source = directory.appendingPathComponent("Notes.pdf")
		let bytes = Data("%PDF-1.4 sample".utf8)
		try bytes.write(to: source)
		let parentID = UUID()
		let service = MockService { id in
			#expect(id == parentID)
			return ItemsPage(items: [], nextCursor: nil)
		}
		service.uploadHandler = { _ in throw URLError(.notConnectedToInternet) }
		let model = FolderViewModel(
			folder: FolderLocation(id: parentID, name: "Documents"),
			service: service
		)

		await model.importPDF(from: source)

		let pending = try #require(model.pendingUpload)
		defer { try? FileManager.default.removeItem(at: pending.localURL) }
		#expect(pending.parentID == parentID)
		#expect(pending.name == "Notes.pdf")
		#expect(try Data(contentsOf: pending.localURL) == bytes)
		#expect(model.showsUploadError)
		#expect(!model.isUploading)
		#expect(service.requestCount == 0)

		service.uploadHandler = { upload in
			#expect(upload.id == pending.id)
			#expect(upload.localURL == pending.localURL)
			return FileItem(id: upload.id, kind: .file, name: upload.name, byteCount: upload.byteCount)
		}
		await model.uploadPendingFile()

		#expect(model.pendingUpload == nil)
		#expect(!model.isUploading)
		#expect(!model.showsUploadError)
		#expect(!FileManager.default.fileExists(atPath: pending.localURL.path))
		#expect(FileManager.default.fileExists(atPath: source.path))
		#expect(service.requestCount == 1)
	}

	@Test func deletionKeepsRowUntilSuccessAndIgnoresDuplicateRequests() async {
		let file = FileItem(id: UUID(), kind: .file, name: "Notes.pdf", byteCount: 3)
		let service = MockService { _ in ItemsPage(items: [file], nextCursor: "next") }
		let model = FolderViewModel(folder: .root, service: service)
		await model.load()
		var calls = 0
		service.deleteHandler = { id in
			calls += 1
			#expect(id == file.id)
			#expect(model.deletingFileID == file.id)
			guard case .loaded(let page) = model.state else {
				Issue.record("The list should remain visible while deleting")
				return
			}
			#expect(page.items.map(\.id) == [file.id])
			await model.deleteFile(file)
		}

		await model.deleteFile(file)

		#expect(calls == 1)
		#expect(model.deletingFileID == nil)
		#expect(!model.showsDeleteError)
		guard case .loaded(let page) = model.state else {
			Issue.record("Expected loaded folder after deleting")
			return
		}
		#expect(page.items.isEmpty)
		#expect(page.nextCursor == "next")
	}

	@Test func failedDeletionKeepsRowAndCanRetry() async {
		let file = FileItem(id: UUID(), kind: .file, name: "Notes.pdf", byteCount: 3)
		let service = MockService { _ in ItemsPage(items: [file], nextCursor: nil) }
		let model = FolderViewModel(folder: .root, service: service)
		await model.load()
		service.deleteHandler = { _ in throw URLError(.notConnectedToInternet) }

		await model.deleteFile(file)

		#expect(model.deletingFileID == nil)
		#expect(model.showsDeleteError)
		#expect(model.deleteErrorMessage == URLError(.notConnectedToInternet).localizedDescription)
		guard case .loaded(let page) = model.state else {
			Issue.record("Failed deletion should keep the folder loaded")
			return
		}
		#expect(page.items.map(\.id) == [file.id])
		service.deleteHandler = { _ in }
		await model.deleteFile(file)
		#expect(!model.showsDeleteError)
		guard case .loaded(let updated) = model.state else {
			Issue.record("Expected the folder to stay loaded after retrying deletion")
			return
		}
		#expect(updated.items.isEmpty)
	}

	@Test func olderPageAndRefreshCannotRestoreDeletedFile() async {
		let file = FileItem(id: UUID(), kind: .file, name: "Notes.pdf", byteCount: 3)
		let other = FileItem(id: UUID(), kind: .file, name: "Other.pdf", byteCount: 3)
		let service = MockService { _ in ItemsPage(items: [file], nextCursor: "next") }
		let model = FolderViewModel(folder: .root, service: service)
		service.deleteHandler = { _ in }
		await model.load()
		service.pageHandler = { _ in
			await model.deleteFile(file)
			return ItemsPage(items: [file, other], nextCursor: nil)
		}
		await model.loadMore()
		guard case .loaded(let page) = model.state else {
			Issue.record("Expected a loaded page")
			return
		}
		#expect(page.items.map(\.id) == [other.id])
		await model.load()
		guard case .loaded(let refreshed) = model.state else {
			Issue.record("Expected a refreshed folder")
			return
		}
		#expect(refreshed.items.isEmpty)
	}

	@Test func deletingFileDiscardsAnInFlightPreview() async throws {
		let file = FileItem(id: UUID(), kind: .file, name: "Notes.pdf", byteCount: 3)
		let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try Data("PDF".utf8).write(to: localURL)
		defer { try? FileManager.default.removeItem(at: localURL) }
		let service = MockService { _ in ItemsPage(items: [file], nextCursor: nil) }
		service.deleteHandler = { _ in }
		let model = FolderViewModel(
			folder: .root,
			service: service,
			previewDownloader: MockPreviewDownloader { _ in localURL }
		)
		service.downloadHandler = { _ in
			await model.deleteFile(file)
			return DownloadTarget(url: localURL, contentType: "application/pdf", byteCount: 3)
		}
		model.selectedFile = file

		await model.preparePreview(for: file)

		#expect(model.selectedFile == nil)
		#expect(model.previewURL == nil)
		#expect(!model.showsPreviewError)
		#expect(!FileManager.default.fileExists(atPath: localURL.path))
	}

	@Test func cancelledDeletionKeepsRowWithoutAnAlert() async {
		let file = FileItem(id: UUID(), kind: .file, name: "Notes.pdf", byteCount: 3)
		let service = MockService { _ in ItemsPage(items: [file], nextCursor: nil) }
		service.deleteHandler = { _ in throw URLError(.cancelled) }
		let model = FolderViewModel(folder: .root, service: service)
		await model.load()
		await model.deleteFile(file)
		#expect(model.deletingFileID == nil)
		#expect(!model.showsDeleteError)
		guard case .loaded(let page) = model.state else {
			Issue.record("Cancelled deletion should keep the folder loaded")
			return
		}
		#expect(page.items.map(\.id) == [file.id])
	}

	@Test func paginationAppendsUniqueFilesAndStopsAtLastPage() async {
		let first = FileItem(id: UUID(), kind: .file, name: "First.pdf", byteCount: 1)
		let second = FileItem(id: UUID(), kind: .file, name: "Second.pdf", byteCount: 1)
		let service = MockService { _ in ItemsPage(items: [first], nextCursor: "next") }
		service.pageHandler = { cursor in
			#expect(cursor == "next")
			return ItemsPage(items: [first, second, second], nextCursor: nil)
		}
		let model = FolderViewModel(folder: .root, service: service)
		await model.load()
		await model.loadMore()
		guard case .loaded(let page) = model.state else {
			Issue.record("Expected loaded files")
			return
		}
		#expect(page.items.map(\.id) == [first.id, second.id])
		#expect(page.nextCursor == nil)
		service.pageHandler = { _ in
			Issue.record("The last page should stop pagination")
			throw URLError(.badURL)
		}
		await model.loadMore()
		#expect(!model.isLoadingMore)
	}

	@Test func paginationFailureKeepsFilesAndCanRetry() async {
		let first = FileItem(id: UUID(), kind: .file, name: "First.pdf", byteCount: 1)
		let service = MockService { _ in ItemsPage(items: [first], nextCursor: "next") }
		service.pageHandler = { _ in throw URLError(.notConnectedToInternet) }
		let model = FolderViewModel(folder: .root, service: service)
		await model.load()
		await model.loadMore()
		#expect(model.loadMoreError != nil)
		guard case .loaded(let page) = model.state else {
			Issue.record("Existing files should stay visible")
			return
		}
		#expect(page.items.map(\.id) == [first.id])
		#expect(page.nextCursor == "next")
		service.pageHandler = { _ in ItemsPage(items: [], nextCursor: nil) }
		await model.loadMore()
		#expect(model.loadMoreError == nil)
		#expect(!model.isLoadingMore)
	}

	@Test func refreshDiscardsAnOlderPageResponse() async {
		let service = MockService { _ in ItemsPage(items: [], nextCursor: "next") }
		let model = FolderViewModel(folder: .root, service: service)
		await model.load()
		service.pageHandler = { _ in
			// Refresh while the page request is suspended in the service.
			await model.loadMore()  // A duplicate request must be ignored.
			service.handler = { _ in ItemsPage(items: [], nextCursor: nil) }
			await model.load()
			return ItemsPage(
				items: [
					FileItem(id: UUID(), kind: .file, name: "Stale.pdf", byteCount: 1)
				],
				nextCursor: "stale"
			)
		}
		await model.loadMore()
		guard case .loaded(let page) = model.state else {
			Issue.record("Expected the refreshed page")
			return
		}
		#expect(page.items.isEmpty)
		#expect(page.nextCursor == nil)
		#expect(!model.isLoadingMore)
	}

	@Test func failedLoadCanBeRetried() async {
		let service = MockService { _ in throw APIError.unauthorized }
		let model = FolderViewModel(folder: .root, service: service)

		await model.load()
		guard case .failed(let message) = model.state else {
			Issue.record("Expected an error message")
			return
		}
		#expect(message == APIError.unauthorized.localizedDescription)

		service.handler = { _ in ItemsPage(items: [], nextCursor: nil) }
		await model.load()
		guard case .loaded(let page) = model.state else {
			Issue.record("Expected the retry to succeed")
			return
		}
		#expect(page.items.isEmpty)
	}

	@Test func cancellationDoesNotShowAnError() async {
		let model = FolderViewModel(
			folder: .root,
			service: MockService { _ in
				throw URLError(.cancelled)
			}
		)

		await model.load()

		guard case .idle = model.state else {
			Issue.record("Expected cancellation to return to idle")
			return
		}
	}

	@Test func cancelledTaskDoesNotCallService() async {
		let model = FolderViewModel(
			folder: .root,
			service: MockService { _ in
				Issue.record("A cancelled task should not load a folder")
				return ItemsPage(items: [], nextCursor: nil)
			}
		)
		let task = Task { await model.load() }
		task.cancel()
		await task.value

		guard case .idle = model.state else {
			Issue.record("Expected cancellation to return to idle")
			return
		}
	}
}

// MARK: - MockService

@MainActor
private final class MockService: FileyServicing {

	private(set) var requestCount = 0
	var pageHandler: @MainActor (String) async throws -> ItemsPage = { _ in
		throw URLError(.unsupportedURL)
	}

	var downloadHandler: @MainActor (UUID) async throws -> DownloadTarget = { _ in
		throw URLError(.unsupportedURL)
	}

	var handler: @MainActor (UUID?) async throws -> ItemsPage

	init(handler: @escaping @MainActor (UUID?) async throws -> ItemsPage) {
		self.handler = handler
	}

	func getItems(parentID: UUID?, cursor: String?) async throws -> ItemsPage {
		if let cursor { return try await pageHandler(cursor) }
		requestCount += 1
		return try await handler(parentID)
	}

	func getDownloadTarget(fileID: UUID) async throws -> DownloadTarget {
		try await downloadHandler(fileID)
	}

	var deleteHandler: @MainActor (UUID) async throws -> Void = { _ in
		throw URLError(.unsupportedURL)
	}

	func deleteFile(id: UUID) async throws {
		try await deleteHandler(id)
	}

	var uploadHandler: @MainActor (PendingUpload) async throws -> FileItem = { _ in
		throw URLError(.unsupportedURL)
	}

	func uploadFile(_ upload: PendingUpload) async throws -> FileItem {
		try await uploadHandler(upload)
	}
}

@MainActor
private struct MockPreviewDownloader: PreviewDownloading {
	let handler: @MainActor (DownloadTarget) async throws -> URL

	func download(_ target: DownloadTarget) async throws -> URL {
		try await handler(target)
	}
}
