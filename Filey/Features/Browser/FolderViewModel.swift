//
//  FolderViewModel.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import Foundation
import Observation
import PhotosUI
import SwiftUI

@MainActor
@Observable
final class FolderViewModel {

	enum State {
		case idle
		case loading
		case loaded(ItemsPage)
		case failed(String)
	}

	let folder: FolderLocation

	private(set) var state: State = .idle

	private(set) var isLoadingMore = false

	private(set) var loadMoreError: String?

	// A slower, older request should never replace the latest result.
	private var latestRequestID: UUID?

	private var latestPageRequestID: UUID?

	var selectedFile: FileItem?

	var previewURL: URL? {
		didSet {
			if let oldValue, oldValue != previewURL {
				try? FileManager.default.removeItem(at: oldValue)
			}
		}
	}

	private(set) var previewErrorMessage = ""

	var showsPreviewError = false

	private let previewDownloader: any PreviewDownloading

	private var latestPreviewRequestID: UUID?

	private(set) var isUploading = false

	private(set) var pendingUpload: PendingUpload?

	private(set) var uploadErrorMessage = ""

	var showsUploadError = false

	private let service: any FileyServicing

	init(
		folder: FolderLocation,
		service: any FileyServicing,
		previewDownloader: (any PreviewDownloading)? = nil
	) {
		self.folder = folder
		self.service = service
		self.previewDownloader = previewDownloader ?? PreviewDownloader()
	}

	// MARK: - Folder loading

	/// Loads the folder if we haven't started yet.
	func loadIfNeeded() async {
		guard case .idle = state else { return }
		await load()
	}

	/// Appends the next page without hiding the files already on screen.
	func loadMore() async {
		guard !isLoadingMore,
			case .loaded(let current) = state,
			let cursor = current.nextCursor
		else {
			return
		}
		let requestID = UUID()
		latestPageRequestID = requestID
		isLoadingMore = true
		loadMoreError = nil
		defer {
			if latestPageRequestID == requestID {
				isLoadingMore = false
			}
		}
		do {
			try Task.checkCancellation()
			let page = try await service.getItems(parentID: folder.id, cursor: cursor)
			try Task.checkCancellation()
			guard latestPageRequestID == requestID else {
				return
			}
			// A repeated cursor would keep the visible footer requesting forever.
			guard page.nextCursor != cursor else {
				throw APIError.invalidData
			}
			var ids = Set(current.items.map(\.id))
			let newItems = page.items.filter {
				ids.insert($0.id).inserted
			}
			state = .loaded(
				ItemsPage(items: current.items + newItems, nextCursor: page.nextCursor)
			)
		} catch {
			guard latestPageRequestID == requestID else {
				return
			}
			guard !Task.isCancelled,
				!(error is CancellationError),
				(error as? URLError)?.code != .cancelled
			else {
				return
			}
			loadMoreError = error.localizedDescription
		}
	}

	func load() async {
		latestPageRequestID = nil
		isLoadingMore = false
		loadMoreError = nil
		let requestID = UUID()
		latestRequestID = requestID
		state = .loading
		do {
			try Task.checkCancellation()
			let page = try await service.getItems(
				parentID: folder.id,
				cursor: nil
			)

			try Task.checkCancellation()

			guard latestRequestID == requestID else {
				return
			}

			state = .loaded(page)
		} catch {
			guard latestRequestID == requestID else {
				return
			}

			if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
				state = .idle
				return
			}

			state = .failed(error.localizedDescription)
		}
	}

	// MARK: - File previews

	/// Prepares a local file and leaves presentation to the view.
	func preparePreview(for file: FileItem) async {
		let requestID = UUID()
		latestPreviewRequestID = requestID
		showsPreviewError = false
		defer {
			if latestPreviewRequestID == requestID,
				selectedFile?.id == file.id
			{
				selectedFile = nil
			}
		}
		do {
			try Task.checkCancellation()
			let target = try await service.getDownloadTarget(fileID: file.id)
			try Task.checkCancellation()
			let localURL = try await previewDownloader.download(target)
			guard !Task.isCancelled,
				latestPreviewRequestID == requestID,
				selectedFile?.id == file.id
			else {
				try? FileManager.default.removeItem(at: localURL)
				return
			}
			previewURL = localURL
		} catch {
			guard latestPreviewRequestID == requestID,
				selectedFile?.id == file.id,
				!Task.isCancelled,
				!(error is CancellationError),
				(error as? URLError)?.code != .cancelled
			else {
				return
			}
			previewErrorMessage = error.localizedDescription
			showsPreviewError = true
		}
	}

	// MARK: - Imports and uploads

	/// Copies the selected PDF and starts uploading.
	func importPDF(from source: URL) async {
		await importFile {
			try await PDFImporter.stage(source: source, parentID: folder.id)
		}
	}

	/// Loads the selected photo, prepares a JPEG, and starts uploading.
	func importPhoto(_ photo: PhotosPickerItem) async {
		await importFile {
			guard let data = try await photo.loadTransferable(type: Data.self) else {
				throw FileImportError.invalidPhoto
			}
			try Task.checkCancellation()
			return try await PhotoImporter.stage(data: data, parentID: folder.id)
		}
	}

	func uploadPendingFile() async {
		guard !isUploading,
			let upload = pendingUpload
		else {
			return
		}

		isUploading = true
		showsUploadError = false
		defer {
			isUploading = false
		}

		do {
			_ = try await service.uploadFile(upload)

			try? FileManager.default.removeItem(at: upload.localURL)
			pendingUpload = nil

			await load()
		} catch {
			// Keep the UUID and staged file so Retry resumes this upload.
			handleUploadError(error)
		}
	}

	func handleUploadError(_ error: any Error) {
		guard !Task.isCancelled,
			!(error is CancellationError),
			(error as? URLError)?.code != .cancelled
		else {
			return
		}
		uploadErrorMessage = error.localizedDescription
		showsUploadError = true
	}

	/// Keeps preparation and error handling the same for PDFs and photos.
	private func importFile(prepare: () async throws -> PendingUpload) async {
		guard !isUploading, pendingUpload == nil else { return }
		isUploading = true
		showsUploadError = false
		do {
			pendingUpload = try await prepare()
		} catch {
			isUploading = false
			handleUploadError(error)
			return
		}
		isUploading = false
		await uploadPendingFile()
	}
}
