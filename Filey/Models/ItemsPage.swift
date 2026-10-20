//
//  ItemsPage.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import Foundation

struct ItemsPage: Decodable, Sendable {
	let items: [FileItem]
	let nextCursor: String?

	enum CodingKeys: String, CodingKey {
		case items
		case nextCursor = "next_cursor"
	}
}
