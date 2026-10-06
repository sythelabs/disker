import AppKit
import SwiftUI

enum OnboardingArtworkError: Error, LocalizedError, Equatable {
    case missingResource
    case unreadableResource(String)

    var errorDescription: String? {
        switch self {
        case .missingResource: return "DiskerMouse.png is missing from the app bundle. Reinstall Disker."
        case .unreadableResource(let path): return "Could not decode the Disker mouse image at " + path
        }
    }
}

func loadOnboardingMouse(bundle: Bundle) throws(OnboardingArtworkError) -> NSImage {
    guard let url: URL = bundle.url(forResource: "DiskerMouse", withExtension: "png") else {
        throw .missingResource
    }
    guard let image: NSImage = NSImage(contentsOf: url) else {
        throw .unreadableResource(url.path)
    }
    return image
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case access
    case scan

    var title: String {
        switch self {
        case .welcome: return "See where your space goes"
        case .access: return "Give Disker Full Disk Access"
        case .scan: return "Your first scan"
        }
    }

    var description: String {
        switch self {
        case .welcome: return "Find your largest folders, explore what's inside, and see how your disk space adds up."
        case .access: return "Scan protected folders and reduce repeated permission prompts. You stay in control of access in macOS."
        case .scan: return "Disker builds a local index so you can explore your files without scanning them again every time."
        }
    }
}

struct OnboardingView: View {
    let mouseImage: NSImage
    let access: DiskAccessStatus
    let saving: Bool
    let onRecheck: () -> Void
    let onComplete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @State private var step: OnboardingStep = .welcome
    @State private var settingsError: String?

    init(mouseImage: NSImage, initialStep: OnboardingStep, access: DiskAccessStatus, saving: Bool, onRecheck: @escaping () -> Void, onComplete: @escaping () -> Void) {
        self.mouseImage = mouseImage
        self.access = access
        self.saving = saving
        self.onRecheck = onRecheck
        self.onComplete = onComplete
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                Text("Welcome to Disker").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 32).padding(.vertical, 20)
            Divider()
            VStack(spacing: 24) {
                illustration.frame(height: 240)
                VStack(spacing: 10) {
                    Text(step.title).font(.largeTitle.bold())
                    Text(step.description)
                        .font(.title3).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 580)
                        .fixedSize(horizontal: false, vertical: true)
                }
                details.frame(height: 190, alignment: .top)
            }
            .id(step.rawValue)
            .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 8)))
            .padding(32)
            .frame(maxWidth: 780, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Back") { if let previous: OnboardingStep = OnboardingStep(rawValue: step.rawValue - 1) { step = previous } }
                    .disabled(step == .welcome)
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Spacer()
                HStack(spacing: 8) {
                    ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                        Circle().fill(item == step ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(step.rawValue + 1) of 3")
                Spacer()
                Button(step == .scan ? "Start Scanning" : "Continue") {
                    if step == .scan { onComplete() }
                    else if let next: OnboardingStep = OnboardingStep(rawValue: step.rawValue + 1) { step = next }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || (step != .welcome && access != .allowed))
            }
            .controlSize(.large)
            .padding(.horizontal, 32).padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 780, minHeight: 820)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: step)
        .onChange(of: access) { _, status in
            if step == .scan, status != .allowed, status != .checking { step = .access }
        }
        .alert("Could not open System Settings", isPresented: Binding(get: { settingsError != nil }, set: { if !$0 { settingsError = nil } })) {
            Button("OK", role: .cancel) { settingsError = nil }
        } message: { Text(settingsError ?? "") }
    }

    @ViewBuilder private var illustration: some View {
        switch step {
        case .welcome:
            HStack(spacing: 24) {
                VStack(spacing: 12) {
                    DiskerMouse(image: mouseImage, size: 150)
                    Text("Hi, I'm Disker").font(.headline)
                }
                SampleTreePreview()
            }
        case .access: AccessIllustration()
        case .scan:
            HStack(spacing: 32) {
                Image(systemName: "folder.fill").foregroundStyle(.blue)
                    .font(.system(size: 72)).accessibilityHidden(true)
                Image(systemName: "arrow.right").font(.title).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                VStack(spacing: 12) {
                    Image(systemName: "internaldrive.fill").font(.system(size: 84))
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    Label("Local index", systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder private var details: some View {
        switch step {
        case .welcome:
            Label("Try expanding Projects or sorting the sample above.", systemImage: "cursorarrow.click")
                .foregroundStyle(.secondary).padding(.top, 12)
        case .access:
            VStack(spacing: 12) {
                Button("Open Full Disk Access Settings", systemImage: "gearshape") { openAccessSettings() }
                    .controlSize(.large)
                Text("Enable Disker. If it is missing, use + to add Disker from Applications.\nIf macOS asks you to quit and reopen, return here afterward.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Label(access.message, systemImage: access == .allowed ? "checkmark.circle.fill" : "lock.shield")
                        .foregroundStyle(access == .allowed ? Color.green : Color.secondary)
                    Button("Check Again", action: onRecheck).disabled(access == .checking)
                }.font(.callout)
            }
        case .scan:
            VStack(alignment: .leading, spacing: 12) {
                Label("Starts in your home folder", systemImage: "house")
                Label("The first scan can take time and use noticeable CPU and disk activity.", systemImage: "clock")
                Label("The index uses disk space. Temporary scan data can increase storage use.", systemImage: "internaldrive")
                Label("You can stop a scan and continue later.", systemImage: "pause.circle")
                Divider()
                Label("Your scan data stays on your Mac. We collect no telemetry.", systemImage: "lock.shield")
                    .foregroundStyle(.primary)
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func openAccessSettings() {
        guard let url: URL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") else {
            settingsError = "The Full Disk Access settings URL is invalid."
            return
        }
        guard NSWorkspace.shared.open(url) else {
            settingsError = "Could not open the Full Disk Access page. Open System Settings > Privacy & Security > Full Disk Access."
            return
        }
    }
}

private struct DiskerMouse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @State private var greeting: Int = 0
    let image: NSImage
    let size: CGFloat

    var body: some View {
        Button { greeting += 1 } label: {
            Image(nsImage: image)
                .resizable().scaledToFit().frame(width: size, height: size)
                .phaseAnimator([0, 1, 2, 3, 4], trigger: greeting) { mouse, phase in
                    let tilt: Double = phase == 1 ? -8 : phase == 2 ? 8 : 0
                    let hop: CGFloat = phase == 3 ? -14 : 0
                    mouse
                        .rotationEffect(.degrees(reduceMotion ? 0 : tilt))
                        .offset(y: reduceMotion ? 0 : hop)
                        .scaleEffect(reduceMotion || phase != 3 ? 1 : 1.06)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: size * 0.13)).foregroundStyle(.pink)
                                .offset(x: 4, y: 8)
                                .opacity(!reduceMotion && phase == 3 ? 1 : 0)
                                .scaleEffect(phase == 3 ? 1 : 0.2)
                        }
                } animation: { phase in
                    reduceMotion ? nil : .spring(duration: phase == 3 ? 0.3 : 0.24, bounce: 0.35)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Say hello to Disker")
        .help("Click the mouse to say hello")
        .onAppear { greeting += 1 }
        .onHover { hovering in if hovering { greeting += 1 } }
    }
}

private struct SampleFolder: Identifiable {
    let name: String
    let size: String
    let proportion: Double
    let symbol: String

    var id: String { name }
}

private struct SampleTreePreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @State private var expanded: Bool = false
    @State private var sorted: Bool = false
    @State private var selected: String = "Projects"
    private let folders: [SampleFolder] = [
        SampleFolder(name: "Projects", size: "24.6 GB", proportion: 0.72, symbol: "folder.fill"),
        SampleFolder(name: "Downloads", size: "8.2 GB", proportion: 0.24, symbol: "folder.fill"),
        SampleFolder(name: "Pictures", size: "32.4 GB", proportion: 0.95, symbol: "folder.fill")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Your home folder", systemImage: "house.fill").font(.headline)
                Spacer()
                Text("Sample data").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            HStack {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Proportion").frame(width: 140, alignment: .leading)
                Button { sorted.toggle() } label: {
                    HStack(spacing: 4) {
                        Text("Allocated size")
                        Image(systemName: sorted ? "chevron.down" : "arrow.up.arrow.down")
                    }
                }
                .buttonStyle(.plain).frame(width: 112, alignment: .trailing)
                .help("Sort sample folders by size")
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            VStack(spacing: 0) {
                ForEach(sorted ? folders.sorted { $0.proportion > $1.proportion } : folders) { folder in
                    sampleRow(folder, inset: 0)
                    if folder.name == "Projects", expanded {
                        sampleRow(SampleFolder(name: "Disker", size: "4.1 GB", proportion: 0.12, symbol: "folder.fill"), inset: 24)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: expanded)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: sorted)
    }

    private func sampleRow(_ folder: SampleFolder, inset: CGFloat) -> some View {
        HStack(spacing: 8) {
            if folder.name == "Projects" {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption).frame(width: 12)
                }
                .buttonStyle(.plain).accessibilityLabel(expanded ? "Collapse Projects" : "Expand Projects")
            } else { Color.clear.frame(width: 12, height: 12) }
            Label(folder.name, systemImage: folder.symbol)
                .labelStyle(.titleAndIcon).foregroundStyle(selected == folder.name ? .white : .primary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, inset)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 3)
                    .fill(selected == folder.name ? Color.white.opacity(0.75) : Color.accentColor.opacity(0.6))
                    .frame(width: geometry.size.width * folder.proportion)
            }.frame(width: 140, height: 10)
                .accessibilityLabel("Proportion \(Int(folder.proportion * 100)) percent")
            Text(folder.size).monospacedDigit().frame(width: 112, alignment: .trailing)
        }
        .foregroundStyle(selected == folder.name ? .white : .primary)
        .padding(.horizontal, 16).frame(height: 38)
        .background(selected == folder.name ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selected = folder.name }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Select \(folder.name)") { selected = folder.name }
    }
}

private struct AccessIllustration: View {
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "gearshape.fill").font(.system(size: 38)).foregroundStyle(.secondary)
                Text("System Settings").font(.headline)
                Label("Privacy & Security", systemImage: "hand.raised.fill")
                    .font(.callout).padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Spacer()
            }.padding(22).frame(width: 240)
            Divider()
            VStack(alignment: .leading, spacing: 22) {
                Text("Full Disk Access").font(.title2.bold())
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage).resizable()
                        .frame(width: 44, height: 44).accessibilityHidden(true)
                    Text("Disker").font(.headline)
                    Spacer()
                    Toggle("Enable Disker", isOn: .constant(true)).labelsHidden()
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Label("Enable Disker's toggle here", systemImage: "cursorarrow.click")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }.padding(24)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1))
    }
}
