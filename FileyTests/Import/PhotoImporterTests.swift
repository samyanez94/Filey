import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Filey

@MainActor
struct PhotoImporterTests {
	@Test(arguments: [1, 6])
	func stagesOrientedJPEGWithUploadMetadata(orientation: Int) async throws {
		let data = try makePhoto(orientation: orientation)
		let parentID = UUID()

		let upload = try await PhotoImporter.stage(data: data, parentID: parentID)
		defer {
			try? FileManager.default.removeItem(at: upload.localURL)
		}

		#expect(upload.parentID == parentID)
		#expect(upload.contentType == "image/jpeg")
		#expect(upload.localURL.pathExtension == "jpg")
		#expect(upload.name.hasSuffix(".jpg"))
		let bytes = try Data(contentsOf: upload.localURL)
		#expect(Int64(bytes.count) == upload.byteCount)
		#expect(upload.byteCount > 0 && upload.byteCount <= 20_000_000)

		let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
		#expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
		let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
		#expect(max(image.width, image.height) == 2_560)
		#expect(orientation == 6 ? image.height > image.width : image.width > image.height)

		let json = try #require(
			JSONSerialization.jsonObject(with: JSONEncoder().encode(upload)) as? [String: Any]
		)
		#expect(json["content_type"] as? String == "image/jpeg")
		#expect(json["parent_id"] as? String == parentID.uuidString)
	}

	@Test func rejectsInvalidPhotoData() async {
		await #expect {
			try await PhotoImporter.stage(data: Data("not an image".utf8), parentID: nil)
		} throws: { error in
			guard case FileImportError.invalidPhoto = error else { return false }
			return true
		}
	}

	@Test func cancelledImportStopsBeforeDecoding() async {
		let task = Task {
			try await PhotoImporter.stage(data: Data(), parentID: nil)
		}
		task.cancel()

		await #expect(throws: CancellationError.self) {
			try await task.value
		}
	}

	private func makePhoto(orientation: Int) throws -> Data {
		let context = try #require(
			CGContext(
				data: nil,
				width: 3_000,
				height: 1_000,
				bitsPerComponent: 8,
				bytesPerRow: 0,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
			)
		)
		context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: 3_000, height: 1_000))
		let image = try #require(context.makeImage())
		let data = NSMutableData()
		let destination = try #require(
			CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
		)
		CGImageDestinationAddImage(
			destination,
			image,
			[kCGImagePropertyOrientation: orientation] as CFDictionary
		)
		try #require(CGImageDestinationFinalize(destination))
		return data as Data
	}
}
