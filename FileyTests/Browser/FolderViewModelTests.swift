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
	var downloadHandler: @MainActor (UUID) async throws -> DownloadTarget = { _ in
		throw URLError(.unsupportedURL)
	}
	var handler: @MainActor (UUID?) async throws -> ItemsPage

	init(handler: @escaping @MainActor (UUID?) async throws -> ItemsPage) {
		self.handler = handler
	}

	func getItems(parentID: UUID?) async throws -> ItemsPage {
		requestCount += 1
		return try await handler(parentID)
	}

	func getDownloadTarget(fileID: UUID) async throws -> DownloadTarget {
		try await downloadHandler(fileID)
	}
}

@MainActor
private struct MockPreviewDownloader: PreviewDownloading {
	let handler: @MainActor (DownloadTarget) async throws -> URL

	func download(_ target: DownloadTarget) async throws -> URL {
		try await handler(target)
	}
}
