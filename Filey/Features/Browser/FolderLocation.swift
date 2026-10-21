//
//  FolderLocation.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import Foundation

/// Identifies a folder and the title to show while browsing it.
struct FolderLocation: Hashable {
	let id: UUID?
	let name: String

	static let root = FolderLocation(
		id: nil,
		name: "My Files"
	)
}
