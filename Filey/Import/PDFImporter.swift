//
//  PDFImporter.swift
//  Filey
//
//  Created by Samuel Yanez on 10/21/26.
//

import Foundation

/// Copies a PDF selected in Files into temporary app storage.
enum PDFImporter {

	/// Makes a local copy we can keep while uploading or retrying.
	///
	/// Handles security-scoped access and file-provider coordination off the main actor.
	/// Pass nil for the root folder. The caller owns the returned copy and removes it
	/// when it is no longer needed. Failed staging removes any partial copy.
	///
	/// Checks file size, but does not parse or validate the PDF contents.
	/// File-access and cancellation errors pass through unchanged.
	@concurrent static func stage(
		source: URL,
		parentID: UUID?
	) async throws -> PendingUpload {
		try Task.checkCancellation()

		let hasAccess = source.startAccessingSecurityScopedResource()
		defer {
			if hasAccess {
				source.stopAccessingSecurityScopedResource()
			}
		}

		let id = UUID()
		let destination = FileManager.default.temporaryDirectory
			.appendingPathComponent(id.uuidString)
			.appendingPathExtension("pdf")

		do {
			try copyFile(from: source, to: destination)
			try Task.checkCancellation()
			let byteCount = try validatedByteCount(at: destination)

			return PendingUpload(
				id: id,
				localURL: destination,
				parentID: parentID,
				name: source.lastPathComponent,
				byteCount: byteCount,
				contentType: "application/pdf"
			)
		} catch {
			try? FileManager.default.removeItem(at: destination)
			throw error
		}
	}

	/// Coordinates access with Files providers before checking and copying the source.
	nonisolated private static func copyFile(from source: URL, to destination: URL) throws {
		var coordinationError: NSError?
		var copyError: (any Error)?

		NSFileCoordinator()
			.coordinate(
				readingItemAt: source,
				options: [],
				error: &coordinationError
			) { readableURL in
				do {
					_ = try validatedByteCount(at: readableURL)
					try FileManager.default.copyItem(at: readableURL, to: destination)
				} catch {
					copyError = error
				}
			}

		if let coordinationError { throw coordinationError }
		if let copyError { throw copyError }
	}

	/// Returns the size of a regular, nonempty file within the 20 MB limit.
	nonisolated private static func validatedByteCount(at url: URL) throws -> Int64 {
		let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
		guard values.isRegularFile == true,
			let size = values.fileSize,
			(1...20_000_000).contains(size)
		else {
			throw FileImportError.invalidSize
		}
		return Int64(size)
	}
}
