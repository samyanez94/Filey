//
//  FileItemRow.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import SwiftUI

struct FileItemRow: View {
	let item: FileItem

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: item.kind == .folder ? "folder" : "doc")
				.foregroundStyle(.blue)
				.accessibilityHidden(true)

			VStack(alignment: .leading, spacing: 4) {
				Text(item.name)

				if item.kind == .folder {
					Text("Folder")
						.font(.caption)
						.foregroundStyle(.secondary)
				} else if let bytes = item.byteCount {
					Text(
						ByteCountFormatter.string(
							fromByteCount: bytes,
							countStyle: .file
						)
					)
					.font(.caption)
					.foregroundStyle(.secondary)
				}
			}
		}
		.accessibilityElement(children: .combine)
	}
}
