import Foundation
import SwiftUI

enum SidebarSection: Hashable {
    case favorites
    case local
    case network
}

struct SidebarSelection: Hashable {
    let section: SidebarSection
    let path: String
}

struct LocationSidebar: View {
    let locations: SidebarLocations
    @Binding var selection: SidebarSelection?
    @State private var favoriteError: String?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(locations.favorites) { location in
                    SidebarLocationRow(location: location)
                        .tag(SidebarSelection(section: .favorites, path: location.id))
                        .contextMenu {
                            Button("Remove from Favorites") { locations.removeFavorite(location.url) }
                        }
                }
                .dropDestination(for: URL.self) { (urls: [URL], index: Int) in
                    addFavorites(urls, at: index)
                }
            } header: {
                Text("Favorites")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .dropDestination(for: URL.self, isEnabled: true) { urls, _ in
                        addFavorites(urls, at: locations.favorites.count)
                    }
            }
            Section("Local") {
                ForEach(locations.local) { location in
                    SidebarLocationRow(location: location)
                        .tag(SidebarSelection(section: .local, path: location.id))
                }
            }
            Section("Network") {
                if locations.network.isEmpty {
                    Label("No mounted network volumes", systemImage: "network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .disabled(true)
                }
                ForEach(locations.network) { location in
                    SidebarLocationRow(location: location)
                        .tag(SidebarSelection(section: .network, path: location.id))
                }
            }
            if let error: String = locations.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .help(error)
                    .disabled(true)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Locations")
        .alert("Could not add to Favorites", isPresented: Binding(get: { favoriteError != nil }, set: { if !$0 { favoriteError = nil } })) {
            Button("OK", role: .cancel) { favoriteError = nil }
        } message: { Text(favoriteError ?? "") }
    }

    private func addFavorites(_ urls: [URL], at index: Int) {
        Task {
            do { try await locations.addFavorites(urls, at: index) }
            catch { favoriteError = error.localizedDescription }
        }
    }
}

private struct SidebarLocationRow: View {
    let location: SidebarLocation

    var body: some View {
        Label(location.title, systemImage: location.systemImage)
            .help(location.url.path)
    }
}
