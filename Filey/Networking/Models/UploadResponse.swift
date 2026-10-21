//
//  UploadResponse.swift
//  Filey
//
//  Created by Samuel Yanez on 10/21/26.
//

import Foundation

/// The upload state returned when starting or resuming an upload.
struct UploadResponse: Decodable, Sendable {
	/// Whether the upload still needs work or has finished.
	let status: Status
	/// The published file when the upload is ready.
	let file: FileItem?
	/// Where to send the bytes when the upload is pending.
	let uploadTarget: UploadTarget?

	/// The upload states understood by the backend.
	enum Status: String, Decodable, Sendable {
		/// Waiting for bytes to be uploaded and verified.
		case pending
		/// Verified and visible in folder listings.
		case ready
		/// Cancelled uploads cannot reuse their ID.
		case cancelled
		/// The upload expired; a new attempt needs a new ID.
		case expired
	}

	enum CodingKeys: String, CodingKey {
		case status
		case file
		case uploadTarget = "upload_target"
	}
}
