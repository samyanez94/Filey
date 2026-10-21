import Foundation
import Testing

@testable import Filey

struct PDFImporterTests {
	@Test(arguments: [0, 20_000_001])
	func rejectsInvalidSize(byteCount: Int) async throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
		try Data(repeating: 0, count: byteCount).write(to: url)
		defer {
			try? FileManager.default.removeItem(at: url)
		}

		await #expect {
			try await PDFImporter.stage(source: url, parentID: nil)
		} throws: { error in
			guard case FileImportError.invalidSize = error else { return false }
			return true
		}
	}

	@Test @MainActor func rootUploadEncodesNullParentWithoutLocalFields() throws {
		let upload = PendingUpload(
			id: UUID(),
			localURL: URL(filePath: "/tmp/test.pdf"),
			parentID: nil,
			name: "Test.pdf",
			byteCount: 123,
			contentType: "application/pdf"
		)
		let data = try JSONEncoder().encode(upload)
		let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

		#expect(json["parent_id"] is NSNull)
		#expect(json["content_type"] as? String == "application/pdf")
		#expect(json["byte_count"] as? Int == 123)
		#expect(Set(json.keys) == ["parent_id", "name", "content_type", "byte_count"])
	}
}
