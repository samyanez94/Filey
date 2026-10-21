import Foundation
import Testing

@testable import Filey

@MainActor
struct PreviewDownloaderTests {
	@Test func downloadsLocalFileWithoutAPIKey() async throws {
		try await withDownloader(
			handler: { request in
				#expect(request.httpMethod == "GET")
				#expect(request.value(forHTTPHeaderField: "X-Filey-API-Key") == nil)
				#expect(request.value(forHTTPHeaderField: "Authorization") == nil)
				#expect(request.url?.query == "token=signed")
				return try Self.response(request)
			},
			test: { downloader, target in
				let url = try await downloader.download(target)
				defer {
					try? FileManager.default.removeItem(at: url)
				}

				#expect(url.isFileURL)
				#expect(url.pathExtension == "pdf")
				#expect(try Data(contentsOf: url) == Data("PDF".utf8))
			}
		)
	}

	@Test func rejectsHTTPError() async throws {
		try await withDownloader(
			handler: { try Self.response($0, status: 403) },
			test: { downloader, target in
				await #expect {
					try await downloader.download(target)
				} throws: { error in
					guard case APIError.server(let status, _) = error else { return false }
					return status == 403
				}
			}
		)
	}

	@Test func rejectsIncompleteDownload() async throws {
		try await withDownloader(
			handler: { try Self.response($0, body: "P") },
			test: { downloader, target in
				await #expect {
					try await downloader.download(target)
				} throws: { error in
					guard case PreviewError.incompleteDownload = error else { return false }
					return true
				}
			}
		)
	}

	@Test func cancelledDownloadDoesNotSendRequest() async throws {
		try await withDownloader(
			handler: { request in
				Issue.record("A cancelled download should not send a request")
				return try Self.response(request)
			},
			test: { downloader, target in
				let task = Task {
					try await downloader.download(target)
				}
				task.cancel()

				await #expect(throws: CancellationError.self) {
					try await task.value
				}
			}
		)
	}

	private func withDownloader(
		handler: @escaping MockURLProtocol.Handler,
		test: (PreviewDownloader, DownloadTarget) async throws -> Void
	) async throws {
		let host = "\(UUID().uuidString.lowercased()).example.test"
		let url = try #require(URL(string: "https://\(host)/file?token=signed"))
		MockURLProtocol.register(handler, for: host)
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [MockURLProtocol.self]
		let session = URLSession(configuration: configuration)
		defer {
			session.invalidateAndCancel()
			MockURLProtocol.removeHandler(for: host)
		}
		let target = DownloadTarget(url: url, contentType: "application/pdf", byteCount: 3)
		try await test(PreviewDownloader(session: session), target)
	}

	nonisolated private static func response(
		_ request: URLRequest,
		status: Int = 200,
		body: String = "PDF"
	) throws -> (URLResponse, Data) {
		let url = try #require(request.url)
		let response = try #require(
			HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
		)
		return (response, Data(body.utf8))
	}
}
