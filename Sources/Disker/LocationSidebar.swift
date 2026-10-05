import Foundation
import SwiftUI

enum SidebarSection: Hashable {
    case favorites
    case starred
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

    var body: some View {
        List(selection: $selection) {
            Section("Favorites") {
                ForEach(locations.favorites) { location in
                    SidebarLocationRow(location: location)
                        .tag(SidebarSelection(section: .favorites, path: location.id))
                }
            }
            Section("Starred Folders") {
                if locations.starred.isEmpty {
                    Text("Use the star button to save a folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .disabled(true)
                }
                ForEach(locations.starred) { location in
                    SidebarLocationRow(location: location)
                        .tag(SidebarSelection(section: .starred, path: location.id))
                        .contextMenu {
                            Button("Unstar Folder", systemImage: "star.slash") { locations.unstar(location.url) }
                        }
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
    }
}

private struct SidebarLocationRow: View {
    let location: SidebarLocation

    var body: some View {
        Label(location.title, systemImage: location.systemImage)
            .help(location.url.path)
    }
}
