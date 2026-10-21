//
//  DownloadTarget.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import Foundation

/// A signed download URL and the metadata used to check its contents.
struct DownloadTarget: Decodable, Sendable {
	/// Temporary Storage access; no Filey API key is needed.
	let url: URL
	/// The MIME type used to choose a local filename extension.
	let contentType: String
	/// Expected download size in bytes, not an integrity checksum.
	let byteCount: Int64

	enum CodingKeys: String, CodingKey {
		case url
		case contentType = "content_type"
		case byteCount = "byte_count"
	}
}
