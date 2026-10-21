//
//  PendingUpload.swift
//  Filey
//
//  Created by Samuel Yanez on 10/21/26.
//

import Foundation

/// A staged PDF and the metadata needed to upload it.
struct PendingUpload: Encodable, Sendable {
	/// Reuse this ID and the same metadata when retrying.
	let id: UUID
	/// Our temporary copy; keep it until the upload finishes or is discarded.
	let localURL: URL
	/// The destination folder, or nil for the root.
	let parentID: UUID?
	/// The original filename shown in the browser.
	let name: String
	/// The size of the staged copy in bytes.
	let byteCount: Int64

	enum CodingKeys: String, CodingKey {
		case parentID = "parent_id"
		case name
		case contentType = "content_type"
		case byteCount = "byte_count"
	}

	/// Encodes API metadata only, including an explicit null parent for root uploads.
	func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)

		// Root uploads explicitly send null.
		try container.encode(parentID, forKey: .parentID)
		try container.encode(name, forKey: .name)
		try container.encode("application/pdf", forKey: .contentType)
		try container.encode(byteCount, forKey: .byteCount)
	}
}
