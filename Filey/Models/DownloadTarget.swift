//
//  DownloadTarget.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import Foundation

struct DownloadTarget: Decodable, Sendable {
	let url: URL
	let contentType: String
	let byteCount: Int64

	enum CodingKeys: String, CodingKey {
		case url
		case contentType = "content_type"
		case byteCount = "byte_count"
	}
}
