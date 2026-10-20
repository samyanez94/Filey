//
//  ContentView.swift
//  Filey
//
//  Created by Samuel Yanez on 10/20/26.
//

import SwiftUI

struct ContentView: View {

	let service: any FileyServicing

	var body: some View {
		NavigationStack {
			FolderView(
				folder: .root,
				service: service
			)
			.navigationDestination(for: FolderLocation.self) { folder in
				FolderView(
					folder: folder,
					service: service
				)
			}
		}
	}
}
