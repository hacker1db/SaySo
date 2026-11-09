import AppKit
import AVFoundation
import SwiftUI

// MARK: - Model

/// UI state shared by the menu, the home window and the recording pill.
/// Stores settings and word/time counters only — never transcripts.
final class AppModel: ObservableObject {
    enum Phase { case idle, listening, finishing }

    @Published var phase: Phase = .idle
    @Published var level: Float = 0
    @Published var status = "Ready"
    @Published var micGranted = false
    @Published var modelReady = false
    @Published var axGranted = false
    @Published var trigger: ShortcutTrigger { didSet { save(trigger.rawValue, "trigger") } }
    @Published private(set) var totalWords: Int
    @Published private(set) var totalSeconds: Double
    @Published private(set) var streak: Int
    private var lastDay: String
    private let persist: Bool

    var onToggle: () -> Void = {}
    var onCancel: () -> Void = {}
    var onPermissions: () -> Void = {}
    var onAccessibility: () -> Void = {}
    var onCopyLast: () -> Void = {}
    var onTriggerChanged: () -> Void = {}

    init(persist: Bool = true) {
        let d = UserDefaults.standard
        self.persist = persist
        trigger = persist ? (ShortcutTrigger(rawValue: d.string(forKey: "trigger") ?? "") ?? .eitherCommand) : .eitherCommand
        totalWords = persist ? d.integer(forKey: "statWords") : 0
        totalSeconds = persist ? d.double(forKey: "statSeconds") : 0
        streak = persist ? d.integer(forKey: "statStreak") : 0
        lastDay = persist ? (d.string(forKey: "statLastDay") ?? "") : ""
    }

    var wordsPerMinute: Int { totalSeconds < 1 ? 0 : Int((Double(totalWords) / (totalSeconds / 60)).rounded()) }
    var userFirstName: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "" }

    func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        modelReady = LocalTranscriber.modelInstalled
        axGranted = AXIsProcessTrusted()
    }

    /// Counts only. `seconds` is how long the microphone was open.
    func record(words: Int, seconds: Double, now: Date = Date()) {
        guard words > 0 else { return }
        totalWords += words
        totalSeconds += max(seconds, 1)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: now)
        let yesterday = f.string(from: now.addingTimeInterval(-86_400))
        if lastDay != today { streak = lastDay == yesterday ? streak + 1 : 1; lastDay = today }
        save(totalWords, "statWords"); save(totalSeconds, "statSeconds"); save(streak, "statStreak"); save(lastDay, "statLastDay")
    }

    func resetStats() {
        totalWords = 0; totalSeconds = 0; streak = 0; lastDay = ""
        for k in ["statWords", "statSeconds", "statStreak", "statLastDay"] where persist { UserDefaults.standard.removeObject(forKey: k) }
    }

    private func save(_ value: Any, _ key: String) { if persist { UserDefaults.standard.set(value, forKey: key) } }

    static func preview() -> AppModel {
        let m = AppModel(persist: false)
        m.totalWords = 12_840; m.totalSeconds = 5_640; m.streak = 6
        m.micGranted = true; m.modelReady = true; m.axGranted = true
        m.status = "Ready · Double-tap ⌘ to dictate"
        return m
    }
}

// MARK: - Theme

struct Theme {
    let dark: Bool
    init(_ scheme: ColorScheme) { dark = scheme == .dark }
    var canvas: Color { dark ? Color(hex: 0x141318) : Color(hex: 0xF3EFE9) }
    var sheet: Color { dark ? Color(hex: 0x1D1C22) : Color(hex: 0xFCFBF8) }
    var card: Color { dark ? Color(hex: 0x26252C) : Color(hex: 0xF4F1EC) }
    var line: Color { dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07) }
    var ink: Color { dark ? Color(hex: 0xF2EFEA) : Color(hex: 0x1E1B22) }
    var muted: Color { dark ? Color(hex: 0xA19EA8) : Color(hex: 0x6E6A73) }
    var selection: Color { dark ? Color.white.opacity(0.07) : Color(hex: 0xE8E2D9) }
    static let ember = Color(hex: 0xF08A5D)
    static let honey = Color(hex: 0xF9C784)
    static let ok = Color(hex: 0x3BAA7A)
    static let warn = Color(hex: 0xE0A23B)
    static let hero = LinearGradient(colors: [Color(hex: 0x17112E), Color(hex: 0x2E1A4A), Color(hex: 0x123F52)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Shared pieces

/// Bars that breathe with `level` (0…1). Used in the pill (live mic) and the hero (decorative).
struct LevelBars: View {
    var level: Float
    var count = 13
    var color: Color = .white
    private static let shape: [Double] = [0.35, 0.55, 0.8, 0.6, 0.95, 0.7, 1.0, 0.75, 0.9, 0.6, 0.8, 0.5, 0.35]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(alignment: .center, spacing: geo.size.width / CGFloat(count) * 0.45) {
                    ForEach(0..<count, id: \.self) { i in
                        let wobble = 0.7 + 0.3 * sin(t * 9 + Double(i) * 1.3)
                        let h = max(0.14, Double(level) * Self.shape[i % Self.shape.count] * wobble)
                        Capsule().fill(color).frame(height: geo.size.height * h)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.25)))
    }
}

struct SoftButton: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Capsule().fill(prominent ? Color.white : Color.primary.opacity(0.08)))
            .foregroundStyle(prominent ? Color.black : Color.primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Main window

enum Page: String, CaseIterable, Identifiable {
    case home, shortcut, permissions, privacy
    var id: String { rawValue }
    var title: String { ["Home", "Shortcut", "Permissions", "Privacy"][Page.allCases.firstIndex(of: self)!] }
    var icon: String {
        switch self {
        case .home: return "house"
        case .shortcut: return "command"
        case .permissions: return "checkmark.shield"
        case .privacy: return "lock"
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var page: Page
    @Environment(\.colorScheme) private var scheme
    private let scrolls: Bool // ImageRenderer draws ScrollView content blank, so previews lay out flat

    init(model: AppModel, page: Page = .home, scrolls: Bool = true) {
        self.model = model
        self.scrolls = scrolls
        _page = State(initialValue: page)
    }

    var body: some View {
        let theme = Theme(scheme)
        HStack(spacing: 0) {
            sidebar(theme)
            Group {
                if scrolls { ScrollView { content } } else { content.frame(maxHeight: .infinity, alignment: .top) }
            }
            .background(RoundedRectangle(cornerRadius: 22).fill(theme.sheet))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(theme.line))
            .padding(.vertical, 12).padding(.trailing, 12)
        }
        .foregroundStyle(theme.ink)
        .background(theme.canvas)
        .frame(minWidth: 860, minHeight: 580)
    }

    private var content: some View {
        Group {
            switch page {
            case .home: HomePage(model: model, go: { page = $0 })
            case .shortcut: ShortcutPage(model: model)
            case .permissions: PermissionsPage(model: model)
            case .privacy: PrivacyPage(model: model)
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sidebar(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                LevelBars(level: 0.9, count: 5, color: theme.ink).frame(width: 22, height: 20)
                Text("Sayso").font(.system(size: 22, weight: .semibold, design: .serif))
            }
            .padding(.horizontal, 12).padding(.top, 40).padding(.bottom, 22)

            ForEach(Page.allCases) { p in
                Button { page = p } label: {
                    HStack(spacing: 12) {
                        Image(systemName: p.icon).frame(width: 18)
                        Text(p.title)
                        Spacer()
                        if p == .permissions && !(model.micGranted && model.modelReady && model.axGranted) {
                            Circle().fill(Theme.warn).frame(width: 7, height: 7)
                        }
                    }
                    .font(.system(size: 14, weight: page == p ? .semibold : .regular))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(page == p ? theme.selection : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            statusChip(theme)
            Button { model.onCopyLast() } label: {
                Label("Copy last transcript", systemImage: "doc.on.clipboard").font(.system(size: 13))
            }
            .buttonStyle(.plain).foregroundStyle(theme.muted).padding(12)
        }
        .padding(.horizontal, 12)
        .frame(width: 228)
    }

    private func statusChip(_ theme: Theme) -> some View {
        HStack(spacing: 8) {
            Circle().fill(model.phase == .idle ? Theme.ok : Theme.ember).frame(width: 8, height: 8)
            Text(model.status).font(.system(size: 12)).foregroundStyle(theme.muted).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.sheet))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.line))
    }
}

struct HomePage: View {
    @ObservedObject var model: AppModel
    var go: (Page) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        VStack(alignment: .leading, spacing: 26) {
            Text(model.userFirstName.isEmpty ? "Welcome back" : "Welcome back, \(model.userFirstName)")
                .font(.system(size: 30, weight: .semibold))

            HStack(alignment: .top, spacing: 18) {
                hero
                stats(theme)
            }

            HStack(spacing: 12) {
                check("Microphone", model.micGranted)
                check("Local model", model.modelReady)
                check("Auto-paste", model.axGranted)
                Spacer()
            }

            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield").font(.system(size: 22)).foregroundStyle(theme.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing you say is kept").font(.system(size: 15, weight: .semibold))
                    Text("Audio is transcribed on this Mac by a local Whisper model and is never saved or sent anywhere. Sayso keeps only word counts for the stats above — no transcript history.")
                        .font(.system(size: 13)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(theme.card))
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                (Text("Talk, ") + Text("don’t type.").italic())
                    .font(.system(size: 30, weight: .regular, design: .serif))
                    .fixedSize(horizontal: false, vertical: true) // wrap rather than truncate in narrow windows
                HStack(spacing: 6) {
                    Text(model.trigger.isModifierGesture ? "Double-tap" : "Press")
                    KeyCap(text: model.trigger.keyCap)
                    Text("to talk.")
                }
                .font(.system(size: 14))
                Text("\(model.trigger.stopHint.capitalizedFirst) to finish and paste.")
                    .font(.system(size: 14)).opacity(0.8)
                Button(model.phase == .idle ? "Try it now" : "Stop & paste") { model.onToggle() }
                    .buttonStyle(SoftButton(prominent: true))
                    .padding(.top, 8)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            LevelBars(level: 0.85, count: 9, color: Theme.honey.opacity(0.85))
                .frame(width: 72, height: 96)
        }
        .foregroundStyle(.white)
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 230, maxHeight: 230)
        .background(Theme.hero)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func stats(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            stat(compact(model.totalWords), "words dictated")
            stat("\(model.wordsPerMinute)", "wpm")
            stat("\(model.streak)", model.streak == 1 ? "day streak" : "day streak")
        }
        .padding(24)
        .frame(width: 230, height: 230, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(theme.card))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(.system(size: 34, weight: .regular, design: .serif))
            Text(label).font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }

    private func check(_ title: String, _ ok: Bool) -> some View {
        Button { go(.permissions) } label: {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(ok ? Theme.ok : Theme.warn)
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme(scheme).card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(ok ? "ready" : "needs attention")")
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000 ? String(format: "%.1fK", Double(n) / 1_000) : "\(n)"
    }
}

struct ShortcutPage: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        VStack(alignment: .leading, spacing: 20) {
            Text("Shortcut").font(.system(size: 30, weight: .semibold))
            Text("Double-tap the key to start talking — no need to hold it. Tap it once more to finish and paste. A tap only counts when the key is pressed on its own, so ⌘C, ⌘V and other shortcuts never start dictation.")
                .font(.system(size: 14)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(ShortcutTrigger.allCases) { t in
                    Button { model.trigger = t; model.onTriggerChanged() } label: {
                        HStack(spacing: 12) {
                            Text(t.keyCap)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(width: 84).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 9).fill(theme.sheet))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.line))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                Text(t.isModifierGesture ? "Double-tap, then tap" : "Press, then press again")
                                    .font(.system(size: 12)).foregroundStyle(theme.muted).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: model.trigger == t ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(model.trigger == t ? Theme.ember : theme.muted)
                        }
                        .padding(14)
                        .frame(height: 76)
                        .background(RoundedRectangle(cornerRadius: 14).fill(theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(model.trigger == t ? Theme.ember : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            if model.trigger == .fn {
                Label("If macOS Dictation is set to “Press fn twice” (System Settings › Keyboard › Dictation), both would start. Change that shortcut first.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            if model.trigger.isModifierGesture && !model.axGranted {
                Label("Key gestures need Accessibility access (the same permission as auto-paste). Until it is granted, ⌃⌥Space still works.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13)).foregroundStyle(Theme.warn)
                Button("Grant Accessibility…") { model.onAccessibility() }.buttonStyle(SoftButton())
            }
            Text("⌃⌥Space always works as a backup.").font(.system(size: 12)).foregroundStyle(theme.muted)
        }
    }
}

struct PermissionsPage: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions").font(.system(size: 30, weight: .semibold))
            row("Microphone", "Needed to hear you. A local Whisper model turns speech into text on this Mac.", model.micGranted, "Enable…", model.onPermissions)
            row("Local Whisper model", model.modelReady ? "Installed: ggml-large-v3-turbo." : "Missing. Download ggml-large-v3-turbo.bin into ~/Library/Application Support/Sayso/models.", model.modelReady, "Show folder", { NSWorkspace.shared.open(LocalTranscriber.modelURL.deletingLastPathComponent()) })
            row("Accessibility", "Lets Sayso paste for you and notice key gestures like double-tap ⌘. Without it, transcripts are copied and ⌃⌥Space still works.", model.axGranted, "Open Settings…", model.onAccessibility)
            Text("After rebuilding an ad-hoc signed copy, macOS may ask again.").font(.system(size: 12)).foregroundStyle(Theme(scheme).muted)
        }
    }

    private func row(_ title: String, _ detail: String, _ ok: Bool, _ action: String, _ run: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 22)).foregroundStyle(ok ? Theme.ok : Theme.warn)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(Theme(scheme).muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !ok { Button(action, action: run).buttonStyle(SoftButton()) }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme(scheme).card))
    }
}

struct PrivacyPage: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        VStack(alignment: .leading, spacing: 16) {
            Text("Privacy").font(.system(size: 30, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text("Local only").font(.system(size: 15, weight: .semibold))
                Text("Speech is transcribed by whisper.cpp running on this Mac. Sayso never uses Apple Speech or any cloud service.")
                    .font(.system(size: 13)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18).background(RoundedRectangle(cornerRadius: 16).fill(theme.card))
            VStack(alignment: .leading, spacing: 8) {
                Text("Stored on this Mac").font(.system(size: 15, weight: .semibold))
                Text("Your shortcut choice and three counters (words, minutes, streak). No audio, no transcripts. The last transcript lives in memory until you quit, and on the clipboard until replaced.")
                    .font(.system(size: 13)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
                Button("Reset stats") { model.resetStats() }.buttonStyle(SoftButton()).padding(.top, 4)
            }
            .padding(18).background(RoundedRectangle(cornerRadius: 16).fill(theme.card))
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Recording pill

/// Small, quiet indicator: a translucent capsule with a few level bars. Cancel / finish appear on hover.
struct RecordingPill: View {
    @ObservedObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if hovering {
                control("xmark", "Cancel — nothing is pasted", "Cancel dictation") { model.onCancel() }
            }
            Group {
                if model.phase == .finishing {
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.6)).frame(width: 3, height: 3) }
                    }
                } else {
                    LevelBars(level: max(0.12, model.level), count: 7, color: .white.opacity(0.75))
                }
            }
            .frame(width: 34, height: 12)
            if hovering && model.phase == .listening {
                control("checkmark", "Finish and paste", "Finish and paste") { model.onToggle() }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
        .opacity(hovering ? 1 : 0.85)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .padding(6)
        .fixedSize()
    }

    private func control(_ symbol: String, _ help: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                .frame(width: 16, height: 16).background(Circle().fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(label)
    }
}

private final class ClickThroughHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Bottom-of-screen indicator. Non-activating, so the app you are dictating into keeps focus.
final class PillController {
    private var panel: NSPanel?

    func show(_ model: AppModel) {
        let panel = self.panel ?? make(model)
        self.panel = panel
        // Room for the hover controls so the capsule can grow without clipping.
        let size = CGSize(width: 130, height: 40)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + 18, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func make(_ model: AppModel) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = ClickThroughHost(rootView: RecordingPill(model: model))
        return p
    }
}

// MARK: - Window

final class MainWindowController {
    private var window: NSWindow?

    func show(_ model: AppModel) {
        model.refreshPermissions()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.title = "Sayso"
            w.contentView = NSHostingView(rootView: MainView(model: model))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Offscreen previews (no desktop interaction)

/// `Sayso --render-previews <dir>` writes PNGs of the main screens and the pill, for design review and CI.
enum PreviewRenderer {
    @MainActor static func run(to dir: String) -> Int32 {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let model = AppModel.preview()
        let listening = AppModel.preview(); listening.phase = .listening; listening.level = 0.7
        let jobs: [(String, AnyView)] = [
            ("home-light", AnyView(MainView(model: model, scrolls: false).frame(width: 960, height: 640).environment(\.colorScheme, .light))),
            ("home-dark", AnyView(MainView(model: model, scrolls: false).frame(width: 960, height: 640).environment(\.colorScheme, .dark))),
            ("shortcut-light", AnyView(MainView(model: model, page: .shortcut, scrolls: false).frame(width: 960, height: 640).environment(\.colorScheme, .light))),
            ("pill-listening", AnyView(RecordingPill(model: listening).padding(24).background(Color(hex: 0x2A2A30)))),
        ]
        var failed = false
        for (name, view) in jobs {
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let tiff = r.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { print("failed: \(name)"); failed = true; continue }
            try? png.write(to: url.appendingPathComponent("\(name).png"))
            print("wrote \(name).png")
        }
        return failed ? 1 : 0
    }
}
