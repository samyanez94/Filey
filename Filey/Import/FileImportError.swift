//
//  FileImportError.swift
//  Filey
//
//  Created by Samuel Yanez on 10/21/26.
//

import Foundation

/// Problems found while preparing a file for upload.
enum FileImportError: LocalizedError {
	/// The selection is not a regular file, is empty, or exceeds 20 MB.
	case invalidSize
	/// The selected image could not be decoded or converted to JPEG.
	case invalidPhoto

	/// A readable message for the import alert.
	var errorDescription: String? {
		switch self {
		case .invalidSize:
			"Choose a nonempty file smaller than or equal to 20 MB."
		case .invalidPhoto:
			"This photo couldn't be prepared for upload."
		}
	}
}
