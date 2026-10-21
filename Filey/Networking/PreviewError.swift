//
//  PreviewError.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import Foundation

enum PreviewError: LocalizedError {
	case incompleteDownload
	case unsupportedFile

	var errorDescription: String? {
		switch self {
		case .incompleteDownload:
			"The file didn't finish downloading. Please try again."
		case .unsupportedFile:
			"This file type isn't supported."
		}
	}
}
