//
//  UploadTarget.swift
//  Filey
//
//  Created by Samuel Yanez on 10/21/26.
//

import Foundation

/// Instructions from the backend for sending file bytes directly to Storage.
struct UploadTarget: Decodable, Sendable {
	/// A temporary signed URL for this upload.
	let url: URL
	/// The required HTTP method; Filey currently expects PUT.
	let method: String
	/// Storage request headers. Do not add the Filey API key.
	let headers: [String: String]
	/// Currently raw file bytes, rather than multipart form data.
	let bodyEncoding: String

	enum CodingKeys: String, CodingKey {
		case url
		case method
		case headers
		case bodyEncoding = "body_encoding"
	}
}
