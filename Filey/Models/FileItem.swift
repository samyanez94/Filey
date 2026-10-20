//
//  FileItem.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import Foundation

struct FileItem: Decodable, Identifiable, Sendable {
	let id: UUID
	let kind: Kind
	let name: String
	let byteCount: Int64?

	enum CodingKeys: String, CodingKey {
		case id
		case kind
		case name
		case byteCount = "byte_count"
	}

	enum Kind: String, Decodable, Sendable {
		case folder
		case file
	}
}
