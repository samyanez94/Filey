import Foundation
import Synchronization

/// Each test gets its own URL, so parallel tests don't share responses.
final class MockURLProtocol: URLProtocol {
	typealias Handler = @Sendable (URLRequest) throws -> (URLResponse, Data)

	private static let handlers = Mutex<[String: Handler]>([:])

	static func register(_ handler: @escaping Handler, for host: String) {
		handlers.withLock { $0[host] = handler }
	}

	static func removeHandler(for host: String) {
		handlers.withLock { $0[host] = nil }
	}

	override class func canInit(with request: URLRequest) -> Bool {
        true
    }

	override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

	override func startLoading() {
		guard let host = request.url?.host,
			let handler = Self.handlers.withLock({ $0[host] })
		else {
			client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
			return
		}
		do {
			let (response, data) = try handler(request)
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: data)
			client?.urlProtocolDidFinishLoading(self)
		} catch {
			client?.urlProtocol(self, didFailWithError: error)
		}
	}

	override func stopLoading() {}
}
