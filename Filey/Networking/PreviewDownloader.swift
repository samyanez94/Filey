//
//  PreviewDownloader.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import Foundation
import UniformTypeIdentifiers

@MainActor
protocol PreviewDownloading {
	func download(_ target: DownloadTarget) async throws -> URL
}

@MainActor
final class PreviewDownloader: PreviewDownloading {
	private let session: URLSession

	init(session: URLSession = .shared) {
		self.session = session
	}

	/// Downloads a file and keeps a temporary copy for Quick Look.
	func download(_ target: DownloadTarget) async throws -> URL {
		try Task.checkCancellation()

		// Use a fresh request: the signed URL already grants access.
		let request = URLRequest(url: target.url)

		let (temporaryURL, response) = try await session.download(for: request)

		defer {
			try? FileManager.default.removeItem(at: temporaryURL)
		}

		try Task.checkCancellation()

		guard let response = response as? HTTPURLResponse else {
			throw APIError.invalidResponse
		}

		guard response.statusCode == 200 else {
			throw APIError.server(
				statusCode: response.statusCode,
				requestID: response.value(
					forHTTPHeaderField: "X-Request-ID"
				)
			)
		}

		let attributes = try FileManager.default.attributesOfItem(
			atPath: temporaryURL.path
		)

		let actualSize = (attributes[.size] as? NSNumber)?.int64Value

		guard actualSize == target.byteCount else {
			throw PreviewError.incompleteDownload
		}

		guard
			let fileExtension = UTType(
				mimeType: target.contentType
			)?
			.preferredFilenameExtension
		else {
			throw PreviewError.unsupportedFile
		}

		let destination = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
			.appendingPathExtension(fileExtension)

		try FileManager.default.moveItem(
			at: temporaryURL,
			to: destination
		)

		return destination
	}
}
