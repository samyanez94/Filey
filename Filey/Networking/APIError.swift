//
//  APIError.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import Foundation

/// Things that can go wrong with an API response.
///
/// Network and cancellation errors keep their original types.
enum APIError: LocalizedError {

	/// We didn't get an HTTP response.
	case invalidResponse

	/// The server didn't accept our shared key (HTTP 401).
	case unauthorized

	/// The server returned another HTTP error.
	///
	/// Keeps the status code and request ID to help with debugging.
	case server(statusCode: Int, requestID: String?)

	/// The request succeeded, but the JSON didn't match our model.
	case invalidData

	/// A readable message we can show on screen.
	nonisolated var errorDescription: String? {
		switch self {
		case .invalidResponse:
			return "The server returned an invalid response."
		case .unauthorized:
			return "Check the Filey API key in your local configuration."
		case .server(let statusCode, let requestID):
			let message = "The request failed with HTTP \(statusCode)."
			if let requestID {
				return "\(message)\nRequest ID: \(requestID)"
			}
			return message
		case .invalidData:
			return "The server response didn't match the expected format."
		}
	}
}
