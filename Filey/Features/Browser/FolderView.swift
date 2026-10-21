//
//  FolderView.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import QuickLook
import SwiftUI

struct FolderView: View {

	@State private var viewModel: FolderViewModel

	init(
		folder: FolderLocation,
		service: any FileyServicing
	) {
		_viewModel = State(
			initialValue: FolderViewModel(
				folder: folder,
				service: service
			)
		)
	}

	var body: some View {
		content
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(Color(uiColor: .systemGroupedBackground))
			.navigationTitle(viewModel.folder.name)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Refresh", systemImage: "arrow.clockwise") {
						Task { await viewModel.load() }
					}
				}
			}
			.task {
				await viewModel.loadIfNeeded()
			}
			.task(id: viewModel.selectedFile?.id) {
				guard let selectedFile = viewModel.selectedFile else {
					return
				}
				await viewModel.preparePreview(for: selectedFile)
			}
			.quickLookPreview($viewModel.previewURL)
			.alert(
				"Couldn't Preview File",
				isPresented: $viewModel.showsPreviewError
			) {
				Button("OK", role: .cancel) {}
			} message: {
				Text(viewModel.previewErrorMessage)
			}
	}

	@ViewBuilder
	private var content: some View {
		switch viewModel.state {
		case .idle, .loading:
			ProgressView("Loading files…")
		case .loaded(let page):
			if page.items.isEmpty {
				ContentUnavailableView(
					"This Folder Is Empty",
					systemImage: "folder",
					description: Text("Files and folders will appear here.")
				)
			} else {
				FolderContentsView(
					page: page,
					downloadingFileID: viewModel.selectedFile?.id,
					onSelectFile: { viewModel.selectedFile = $0 }
				)
			}
		case .failed(let message):
			errorView(message: message)
		}
	}

	private func errorView(message: String) -> some View {
		ContentUnavailableView {
			Label("Couldn't Load Folder", systemImage: "exclamationmark.triangle")
		} description: {
			Text(message)
		} actions: {
			Button("Try Again") {
				Task { await viewModel.load() }
			}
			.buttonStyle(.borderedProminent)
		}
	}
}
