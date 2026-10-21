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
		Group {
			switch viewModel.state {
			case .idle, .loading:
				ProgressView("Loading files…")

			case .loaded(let page):
				if page.items.isEmpty {
					ContentUnavailableView(
						"This Folder Is Empty",
						systemImage: "folder",
						description: Text(
							"Files and folders will appear here."
						)
					)
				} else {
					List {
						ForEach(page.items) { item in
							if item.kind == .folder {
								NavigationLink(
									value: FolderLocation(
										id: item.id,
										name: item.name
									)
								) {
									FileItemRow(item: item)
								}
							} else {
								Button {
									viewModel.selectedFile = item
								} label: {
									FileItemRow(item: item)
										.frame(maxWidth: .infinity, alignment: .leading)
										.contentShape(Rectangle())
								}
								.buttonStyle(.plain)
								.disabled(viewModel.selectedFile != nil)
							}
						}
						if page.nextCursor != nil {
							Text("More items are available.")
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
					}
					.scrollContentBackground(.hidden)
				}

			case .failed(let message):
				ContentUnavailableView {
					Label(
						"Couldn't Load Folder",
						systemImage: "exclamationmark.triangle"
					)
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
		.overlay {
			if viewModel.selectedFile != nil {
				VStack(spacing: 12) {
					ProgressView("Downloading file…")
					Button("Cancel", role: .cancel) {
						viewModel.selectedFile = nil
					}
				}
				.padding(24)
				.background(
					Color(uiColor: .secondarySystemGroupedBackground),
					in: RoundedRectangle(cornerRadius: 16)
				)
			}
		}
	}

}
