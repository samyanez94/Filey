//
//  AppConfiguration.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import Foundation

enum AppConfiguration {
	static let apiKey: String? = {
		guard let url = Bundle.main.url(forResource: "LocalConfiguration", withExtension: "plist"),
			let data = try? Data(contentsOf: url),
			let values = try? PropertyListDecoder().decode([String: String].self, from: data)
		else {
			return nil
		}
		return values["FileyAPIKey"]
	}()

	static let baseURL = URL(
		string: "https://bgcdtyjffxtcrciyfewp.supabase.co/functions/v1/api/v1"
	)!
}
