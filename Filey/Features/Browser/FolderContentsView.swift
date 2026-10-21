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
	let onSelectFile: (FileItem) -> Void

	var body: some View {
		List {
			ForEach(page.items) { item in
				row(for: item)
			}
		}
		.contentMargins(.top, 12, for: .scrollContent)
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
