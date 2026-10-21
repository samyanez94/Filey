//
//  FolderViewModel.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import Foundation
import Observation

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

	private let service: any FileyServicing

	// A slower, older request should never replace the latest result.
	private var latestRequestID: UUID?

	init(
		folder: FolderLocation,
		service: any FileyServicing,
		previewDownloader: (any PreviewDownloading)? = nil
	) {
		self.folder = folder
		self.service = service
		self.previewDownloader = previewDownloader ?? PreviewDownloader()
	}

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

	/// Loads the folder if we haven't started yet.
	func loadIfNeeded() async {
		guard case .idle = state else { return }
		await load()
	}

	func load() async {
		let requestID = UUID()
		latestRequestID = requestID
		state = .loading
		do {
			try Task.checkCancellation()
			let page = try await service.getItems(
				parentID: folder.id
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
}
