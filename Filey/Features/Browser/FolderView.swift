//
//  FolderView.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct FolderView: View {

	@State private var viewModel: FolderViewModel

	@State private var showsFileImporter = false

	@State private var showsPhotoPicker = false

	@State private var selectedPhoto: PhotosPickerItem?

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
				ToolbarItem(placement: .topBarTrailing) {
					if viewModel.isUploading {
						ProgressView()
							.accessibilityLabel("Preparing or uploading file")
					} else if viewModel.pendingUpload != nil {
						Button("Retry Upload", systemImage: "arrow.clockwise") {
							Task {
								await viewModel.uploadPendingFile()
							}
						}
					} else {
						Menu {
							Button("Import PDF", systemImage: "doc") {
								showsFileImporter = true
							}

							Button("Choose Photo", systemImage: "photo") {
								showsPhotoPicker = true
							}
						} label: {
							Label("Add", systemImage: "plus")
						}
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
			.fileImporter(
				isPresented: $showsFileImporter,
				allowedContentTypes: [.pdf],
				allowsMultipleSelection: false
			) { result in
				switch result {
				case .success(let urls):
					guard let source = urls.first else {
						return
					}
					Task {
						await viewModel.importPDF(from: source)
					}
				case .failure(let error):
					viewModel.handleUploadError(error)
				}
			}
			.photosPicker(
				isPresented: $showsPhotoPicker,
				selection: $selectedPhoto,
				matching: .images
			)
			.onChange(of: selectedPhoto) { _, photo in
				guard let photo else {
					return
				}
				// Reset so choosing the same photo again still triggers an import.
				selectedPhoto = nil
				Task {
					await viewModel.importPhoto(photo)
				}
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
			.alert(
				"Couldn't Upload File",
				isPresented: $viewModel.showsUploadError
			) {
				Button("OK", role: .cancel) {}
			} message: {
				Text(viewModel.uploadErrorMessage)
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
