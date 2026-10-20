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

	private let service: any FileyServicing

	// A slower, older request should never replace the latest result.
	private var latestRequestID: UUID?

	init(
		folder: FolderLocation,
		service: any FileyServicing
	) {
		self.folder = folder
		self.service = service
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
