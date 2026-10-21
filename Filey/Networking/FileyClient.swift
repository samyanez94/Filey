//
//  FileyClient.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import Foundation

/// Lets screens load files without depending on a specific client.
@MainActor
protocol FileyServicing: Sendable {

	/// Loads a folder page. A nil parent selects the root; a nil cursor starts at the first page.
	func getItems(parentID: UUID?, cursor: String?) async throws -> ItemsPage

	/// Gets a temporary URL for downloading a file.
	func getDownloadTarget(fileID: UUID) async throws -> DownloadTarget

	/// Uploads or resumes a staged file using its existing ID.
	func uploadFile(_ upload: PendingUpload) async throws -> FileItem
}

/// Talks to the Filey API using our shared key.
@MainActor
final class FileyClient: FileyServicing {
	private let baseURL: URL
	private let apiKey: String
	private let session: URLSession

	/// Sets up the client with a server URL and shared key.
	init(
		baseURL: URL,
		apiKey: String,
		session: URLSession = .shared
	) {
		self.baseURL = baseURL
		self.apiKey = apiKey
		self.session = session
	}

	/// Loads a folder page. A nil parent selects the root; a nil cursor starts at the first page.
	///
	/// - Returns: The folders and files, plus a cursor if there’s another page.
	///
	/// - Throws: An `APIError` if the response isn't usable. Network and cancellation
	///   errors pass through unchanged.
	func getItems(parentID: UUID?, cursor: String? = nil) async throws -> ItemsPage {
		var queryItems =
			parentID.map {
				[URLQueryItem(name: "parent_id", value: $0.uuidString)]
			} ?? []
		if let cursor {
			queryItems.append(URLQueryItem(name: "cursor", value: cursor))
		}
		let request = try makeRequest(
			path: "items",
			queryItems: queryItems
		)
		return try await send(request)
	}

	/// Gets a temporary URL for downloading a file.
	func getDownloadTarget(fileID: UUID) async throws -> DownloadTarget {
		var request = try makeRequest(
			path: "files/\(fileID.uuidString)/download-url"
		)
		request.httpMethod = "POST"
		return try await send(request)
	}

	/// Uploads a staged file and publishes it in its folder.
	///
	/// Starts or resumes the upload, sends raw bytes to Storage, then confirms completion. Reusing the same ID lets a retry recover a file that already finished uploading. The caller keeps the local file for retries and removes it after success.
	func uploadFile(_ upload: PendingUpload) async throws -> FileItem {
		var beginRequest = try makeRequest(
			path: "uploads/\(upload.id.uuidString)"
		)
		beginRequest.httpMethod = "PUT"
		beginRequest.setValue(
			"application/json",
			forHTTPHeaderField: "Content-Type"
		)
		beginRequest.httpBody = try JSONEncoder().encode(upload)

		let response: UploadResponse = try await send(beginRequest)

		// A retry may find that the previous attempt already completed.
		if response.status == .ready {
			guard let file = response.file else {
				throw APIError.invalidData
			}
			return file
		}

		guard response.status == .pending,
			let target = response.uploadTarget,
			target.method == "PUT",
			target.bodyEncoding == "raw"
		else {
			throw APIError.invalidData
		}

		try Task.checkCancellation()

		// This is a Storage request, not a Filey API request.
		var storageRequest = URLRequest(url: target.url)
		storageRequest.httpMethod = target.method

		for (name, value) in target.headers {
			storageRequest.setValue(value, forHTTPHeaderField: name)
		}

		let (_, storageResponse) = try await session.upload(
			for: storageRequest,
			fromFile: upload.localURL
		)

		try Task.checkCancellation()

		guard let storageResponse = storageResponse as? HTTPURLResponse else {
			throw APIError.invalidResponse
		}

		guard (200..<300).contains(storageResponse.statusCode) else {
			throw APIError.server(
				statusCode: storageResponse.statusCode,
				requestID: storageResponse.value(
					forHTTPHeaderField: "X-Request-ID"
				)
			)
		}

		var completeRequest = try makeRequest(
			path: "uploads/\(upload.id.uuidString)/complete"
		)
		completeRequest.httpMethod = "POST"

		return try await send(completeRequest)
	}

	/// Adds the route to our base URL and includes the shared key.
	private func makeRequest(
		path: String,
		queryItems: [URLQueryItem] = []
	) throws -> URLRequest {
		let url = baseURL.appending(path: path)
		guard
			var components = URLComponents(
				url: url,
				resolvingAgainstBaseURL: false
			)
		else {
			throw URLError(.badURL)
		}
		components.queryItems = queryItems.isEmpty ? nil : queryItems
		guard let requestURL = components.url else {
			throw URLError(.badURL)
		}
		var request = URLRequest(url: requestURL)
		request.setValue(apiKey, forHTTPHeaderField: "X-Filey-API-Key")
		return request
	}

	/// Turns the response JSON into a model, or throws `APIError.invalidData`.
	private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
		let data = try await sendData(request)
		do {
			return try JSONDecoder().decode(Response.self, from: data)
		} catch is DecodingError {
			throw APIError.invalidData
		}
	}

	/// Sends the request and checks that it succeeded before returning the data.
	///
	/// A 401 means the key wasn't accepted. Other HTTP errors keep the request ID so we can look them up, even when the error body isn't JSON.
	private func sendData(_ request: URLRequest) async throws -> Data {
		try Task.checkCancellation()
		let (data, response) = try await session.data(for: request)
		try Task.checkCancellation()

		guard let response = response as? HTTPURLResponse else {
			throw APIError.invalidResponse
		}
		if response.statusCode == 401 {
			throw APIError.unauthorized
		}
		guard (200..<300).contains(response.statusCode) else {
			throw APIError.server(
				statusCode: response.statusCode,
				requestID: response.value(forHTTPHeaderField: "X-Request-ID")
			)
		}
		return data
	}
}
