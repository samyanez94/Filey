//
//  PreviewError.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import Foundation

/// Problems with a downloaded file before it reaches Quick Look.
enum PreviewError: LocalizedError {
	/// The downloaded size does not match the backend metadata.
	case incompleteDownload
	/// The MIME type has no known filename extension.
	case unsupportedFile

	/// A readable message for the preview alert.
	var errorDescription: String? {
		switch self {
		case .incompleteDownload:
			"The file didn't finish downloading. Please try again."
		case .unsupportedFile:
			"This file type isn't supported."
		}
	}
}
