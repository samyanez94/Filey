import Foundation
import Testing

@testable import Filey

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

@MainActor
private final class MockService: FileyServicing {
	private(set) var requestCount = 0
	var handler: @MainActor (UUID?) async throws -> ItemsPage

	init(handler: @escaping @MainActor (UUID?) async throws -> ItemsPage) {
		self.handler = handler
	}

	func getItems(parentID: UUID?) async throws -> ItemsPage {
		requestCount += 1
		return try await handler(parentID)
	}
}
