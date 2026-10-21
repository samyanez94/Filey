//
//  PhotoImporter.swift
//  Filey
//
//  Created by Samuel Yanez on 10/21/26.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts selected photos into temporary JPEG files.
enum PhotoImporter {

	/// Makes an orientation-correct JPEG, limited to 2,560 pixels on its longest side.
	///
	/// Converts the first image to a still photo without copying the original metadata.
	/// The caller keeps the temporary file for retries and removes it after uploading.
	/// Failed preparation removes any partial output.
	@concurrent static func stage(
		data: Data,
		parentID: UUID?
	) async throws -> PendingUpload {
		try Task.checkCancellation()

		let image = try makeImage(from: data)
		try Task.checkCancellation()

		let id = UUID()
		let name = "Photo-\(id.uuidString.prefix(8)).jpg"

		let destination = FileManager.default.temporaryDirectory
			.appendingPathComponent(id.uuidString)
			.appendingPathExtension("jpg")

		do {
			try writeJPEG(image, to: destination)
			try Task.checkCancellation()

			let attributes = try FileManager.default.attributesOfItem(
				atPath: destination.path
			)
			let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0

			guard (1...20_000_000).contains(byteCount) else {
				throw FileImportError.invalidSize
			}

			return PendingUpload(
				id: id,
				localURL: destination,
				parentID: parentID,
				name: name,
				byteCount: byteCount,
				contentType: "image/jpeg"
			)
		} catch {
			try? FileManager.default.removeItem(at: destination)
			throw error
		}
	}

	/// Decodes a smaller image and applies the original orientation.
	nonisolated private static func makeImage(
		from data: Data
	) throws -> CGImage {
		let sourceOptions =
			[
				kCGImageSourceShouldCache: false
			] as CFDictionary

		guard
			let source = CGImageSourceCreateWithData(
				data as CFData,
				sourceOptions
			)
		else {
			throw FileImportError.invalidPhoto
		}

		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: 2_560,
			kCGImageSourceShouldCacheImmediately: true
		]

		guard
			let image = CGImageSourceCreateThumbnailAtIndex(
				source,
				0,
				options as CFDictionary
			)
		else {
			throw FileImportError.invalidPhoto
		}

		return image
	}

	/// Writes the converted image without copying the original metadata.
	nonisolated private static func writeJPEG(
		_ image: CGImage,
		to url: URL
	) throws {
		guard
			let destination = CGImageDestinationCreateWithURL(
				url as CFURL,
				UTType.jpeg.identifier as CFString,
				1,
				nil
			)
		else {
			throw FileImportError.invalidPhoto
		}

		let options =
			[
				kCGImageDestinationLossyCompressionQuality: 0.85
			] as CFDictionary

		CGImageDestinationAddImage(destination, image, options)

		guard CGImageDestinationFinalize(destination) else {
			throw FileImportError.invalidPhoto
		}
	}
}
