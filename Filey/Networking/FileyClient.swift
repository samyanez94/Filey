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

	/// Loads a folder’s first page. Pass nil for the shared root folder.
	func getItems(parentID: UUID?) async throws -> ItemsPage
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

	/// Loads a folder’s first page. Pass nil for the shared root folder.
	///
	/// - Returns: The folders and files, plus a cursor if there’s another page.
	///
	/// - Throws: An `APIError` if the response isn't usable. Network and cancellation
	///   errors pass through unchanged.
	func getItems(parentID: UUID?) async throws -> ItemsPage {
		let queryItems =
			parentID.map {
				[URLQueryItem(name: "parent_id", value: $0.uuidString)]
			} ?? []
		let request = try makeRequest(
			path: "items",
			queryItems: queryItems
		)
		return try await send(request)
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
