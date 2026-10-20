import Foundation
import Testing

@testable import Filey

@MainActor
struct FileyClientTests {
	@Test func getItemsSendsKeyAndDecodesPage() async throws {
		try await withClient(
			handler: { request in
				#expect(request.url?.path == "/functions/v1/api/v1/items")
				#expect(request.httpMethod == "GET")
				#expect(request.value(forHTTPHeaderField: "X-Filey-API-Key") == "test-key")
				#expect(request.value(forHTTPHeaderField: "Authorization") == nil)
				return try Self.response(
					request,
					body: """
						{"items":[
						    {"id":"10000000-0000-4000-8000-000000000001","kind":"folder","name":"Photos"},
						    {"id":"20000000-0000-4000-8000-000000000002","kind":"file","name":"Notes.pdf","byte_count":128}
						],"next_cursor":"next-page"}
						"""
				)
			},
			test: { client in
				let page = try await client.getItems()
				#expect(page.items.count == 2)
				let folder = try #require(page.items.first)
				#expect(folder.id.uuidString.lowercased() == "10000000-0000-4000-8000-000000000001")
				#expect(folder.kind == .folder)
				#expect(folder.name == "Photos")
				#expect(folder.byteCount == nil)
				let file = try #require(page.items.last)
				#expect(file.name == "Notes.pdf")
				#expect(file.kind == .file)
				#expect(file.byteCount == 128)
				#expect(page.nextCursor == "next-page")
			}
		)
	}

	@Test func emptyPageDecodes() async throws {
		try await withClient(
			handler: {
                try Self.response($0, body: #"{"items":[],"next_cursor":null}"#)
            },
			test: { client in
				let page = try await client.getItems()
				#expect(page.items.isEmpty)
				#expect(page.nextCursor == nil)
			}
		)
	}

	@Test func unauthorizedResponseThrows() async throws {
		try await withClient(
			handler: { try Self.response($0, status: 401) },
			test: { client in
				await #expect {
					try await client.getItems()
				} throws: { error in
					guard case APIError.unauthorized = error else {
                        return false
                    }
					return true
				}
			}
		)
	}

	@Test(arguments: [429, 503], ["request-123", nil] as [String?])
	func serverErrorKeepsStatusAndRequestID(statusCode: Int, requestID: String?) async throws {
		try await withClient(
			handler: {
                try Self.response(
                    $0,
                    status: statusCode,
                    body: "<html>Unavailable</html>",
                    requestID: requestID
                )
            },
			test: { client in
				await #expect {
					try await client.getItems()
				} throws: { error in
					guard case APIError.server(let actualStatus, let actualID) = error else {
                        return false
                    }
					#expect(actualStatus == statusCode)
					#expect(actualID == requestID)
					return true
				}
			}
		)
	}

	@Test(arguments: ["not JSON", #"{"items":"not an array","next_cursor":null}"#])
	func unusableJSONThrowsInvalidData(body: String) async throws {
		try await withClient(
			handler: { try Self.response($0, body: body) },
			test: { client in
				await #expect {
					try await client.getItems()
				} throws: { error in
					guard case APIError.invalidData = error else { return false }
					return true
				}
			}
		)
	}

	@Test func nonHTTPResponseThrowsInvalidResponse() async throws {
		try await withClient(
			handler: { request in
				let url = try #require(request.url)
				return (
                    URLResponse(
                        url: url,
                        mimeType: nil,
                        expectedContentLength: 0,
                        textEncodingName: nil
                    ),
                    Data()
                )
			},
			test: { client in
				await #expect {
					try await client.getItems()
				} throws: { error in
					guard case APIError.invalidResponse = error else {
                        return false
                    }
					return true
				}
			}
		)
	}

	@Test(arguments: [URLError.Code.notConnectedToInternet, .cancelled])
	func networkErrorsPassThrough(code: URLError.Code) async throws {
		try await withClient(
			handler: { _ in throw URLError(code) },
			test: { client in
				await #expect {
					try await client.getItems()
				} throws: { error in
					(error as? URLError)?.code == code
				}
			}
		)
	}

	@Test func cancelledTaskDoesNotSendRequest() async throws {
		try await withClient(
			handler: { request in
				Issue.record("A cancelled task should not send a request")
				return try Self.response(request)
			},
			test: { client in
				// This task inherits the main actor, so it cannot start before we cancel it.
				let task = Task {
                    try await client.getItems()
                }
				task.cancel()
				await #expect(throws: CancellationError.self) {
					try await task.value
				}
			}
		)
	}

	private func withClient(
		handler: @escaping MockURLProtocol.Handler,
		test: (FileyClient) async throws -> Void
	) async throws {
		let host = "\(UUID().uuidString.lowercased()).example.test"
		let url = try #require(URL(string: "https://\(host)/functions/v1/api/v1"))
		MockURLProtocol.register(handler, for: host)
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [MockURLProtocol.self]
		let session = URLSession(configuration: configuration)
		defer {
			session.invalidateAndCancel()
			MockURLProtocol.removeHandler(for: host)
		}
		try await test(FileyClient(baseURL: url, apiKey: "test-key", session: session))
	}

	nonisolated private static func response(
		_ request: URLRequest,
		status: Int = 200,
		body: String = "",
		requestID: String? = "request-123"
	) throws -> (URLResponse, Data) {
		let url = try #require(request.url)
		let headers = requestID.map { ["X-Request-ID": $0] } ?? [:]
		let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )
        )
		return (response, Data(body.utf8))
	}
}
