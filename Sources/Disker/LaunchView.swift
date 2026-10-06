import AppKit
import Combine
import SwiftUI

struct LaunchView: View {
    let rootURL: URL
    let cacheURL: URL
    let accessDirectory: URL
    @State private var store: OnboardingStore?
    @State private var mouseImage: NSImage?
    @State private var completed: Bool = false
    @State private var ready: Bool = false
    @State private var saving: Bool = false
    @State private var access: DiskAccessStatus = .checking
    @State private var failure: String?

    var body: some View {
        Group {
            if ready {
                ContentView(rootURL: rootURL, cacheURL: cacheURL)
            } else if let failure {
                ContentUnavailableView {
                    Label("Could not prepare Disker", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try Again") { Task { await prepare() } }
                }
            } else if let mouseImage, store != nil {
                OnboardingView(mouseImage: mouseImage, initialStep: completed ? .access : .welcome, access: access, saving: saving,
                    onRecheck: { Task { await recheck() } }, onComplete: { Task { await finish() } })
            } else {
                ProgressView("Preparing Disker")
                    .frame(minWidth: 780, minHeight: 820)
            }
        }
        .task { await prepare() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !ready, store != nil { Task { await recheck() } }
        }
    }

    private func prepare() async {
        failure = nil
        do {
            let settingsURL: URL = cacheURL.deletingLastPathComponent().appendingPathComponent("settings.sqlite")
            let opened: OnboardingStore = try await Task.detached(priority: .utility) {
                try OnboardingStore(databaseURL: settingsURL)
            }.value
            completed = try await opened.isComplete()
            mouseImage = try loadOnboardingMouse(bundle: .main)
            store = opened
            await recheck()
        } catch { failure = error.localizedDescription }
    }

    private func recheck() async {
        guard !ready else { return }
        access = .checking
        let directory: URL = accessDirectory
        access = await Task.detached(priority: .utility) { checkDiskAccess(directory: directory) }.value
        if canStartDisker(onboardingComplete: completed, access: access) { ready = true }
    }

    private func finish() async {
        guard !saving, let store else { return }
        saving = true
        defer { saving = false }
        await recheck()
        guard access == .allowed else { return }
        do {
            try await store.complete()
            completed = true
            ready = true
        } catch { failure = "Could not save onboarding completion: " + error.localizedDescription }
    }
}
