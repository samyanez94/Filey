//
//  Filey.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import SwiftUI

@main struct FileyApp: App {

	private let client: FileyClient? = {
		guard let apiKey = AppConfiguration.apiKey,
			!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else {
			return nil
		}
		return FileyClient(baseURL: AppConfiguration.baseURL, apiKey: apiKey)
	}()

	var body: some Scene {
		WindowGroup {
			if let client {
				ContentView(service: client)
			} else {
				ContentUnavailableView(
					"Missing API Key",
					systemImage: "key",
					description: Text(
						"Add your FileyAPIKey to LocalConfiguration.plist, then rebuild the app."
					)
				)
			}
		}
	}
}
