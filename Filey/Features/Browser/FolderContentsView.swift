//
//  FolderContentsView.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import SwiftUI

struct FolderContentsView: View {
	let page: ItemsPage
	let downloadingFileID: UUID?
	let loadMoreError: String?
	let onLoadMore: () async -> Void
	let onSelectFile: (FileItem) -> Void

	var body: some View {
		List {
			ForEach(page.items) { item in
				row(for: item)
			}
			if let cursor = page.nextCursor {
				paginationFooter(cursor: cursor)
			}
		}
		.contentMargins(.top, 12, for: .scrollContent)
	}

	@ViewBuilder
	private func paginationFooter(cursor: String) -> some View {
		if let loadMoreError {
			VStack(spacing: 8) {
				Text("Couldn't load more files.")
				Text(loadMoreError)
					.font(.caption)
					.foregroundStyle(.secondary)
				Button("Retry") {
					Task {
						await onLoadMore()
					}
				}
			}
			.frame(maxWidth: .infinity)
		} else {
			ProgressView()
				.accessibilityLabel("Loading more files")
				.frame(maxWidth: .infinity)
				.task(id: cursor) {
					await onLoadMore()
				}
		}
	}

	@ViewBuilder
	private func row(for item: FileItem) -> some View {
		if item.kind == .folder {
			NavigationLink(value: FolderLocation(id: item.id, name: item.name)) {
				FileItemRow(item: item)
			}
		} else {
			Button {
				onSelectFile(item)
			} label: {
				FileItemRow(
					item: item,
					isDownloading: downloadingFileID == item.id
				)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
		}
	}
}
