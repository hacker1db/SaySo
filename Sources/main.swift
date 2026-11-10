import AppKit
import AVFoundation
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement

final class DictationApp: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private let menu = NSMenu()
    private var toggleItem: NSMenuItem!
    private var stateItem: NSMenuItem!
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var engine = AVAudioEngine()
    private let transcriber = LocalTranscriber()
    private var collector: AudioCollector?
    private var tapInstalled = false
    private var recording = false
    private var finishing = false
    private var transcript = ""
    private var lastTranscript = ""
    private var generation = UUID()
    private var timeout: DispatchWorkItem?
    private var target: NSRunningApplication?
    private var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var audioObserver: NSObjectProtocol?
    private var modalVisible = false
    private var interruption: String?
    private var dockItem: NSMenuItem!
    private var showInDock: Bool { UserDefaults.standard.bool(forKey: "showInDock") }
    private var isolationItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    /// Echo cancellation + noise suppression (Apple voice processing). Off by default: macOS always ducks other audio while it runs.
    private var voiceIsolation: Bool { UserDefaults.standard.bool(forKey: "voiceIsolation") }
    private let model = AppModel()
    private let pill = PillController()
    private let window = MainWindowController()
    private var gesture = TapGesture()
    private var gestureMonitors: [Any] = []
    private var gestureTrusted = false
    private var holdTimer: DispatchWorkItem?
    private var permissionTimer: Timer?
    private var startedAt = Date()
    /// `--self-test <seconds>`: record from the microphone, transcribe locally, log the text and quit. Never copies or pastes.
    private let selfTestSeconds: Double? = CommandLine.arguments.firstIndex(of: "--self-test").flatMap {
        CommandLine.arguments.count > $0 + 1 ? Double(CommandLine.arguments[$0 + 1]) : nil
    }
    private var readyHint: String { "Ready · \(model.trigger.startHint) to dictate" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "SaySo"
        menu.autoenablesItems = false
        stateItem = item(readyHint, action: nil)
        stateItem.isEnabled = false
        toggleItem = item("Start dictation", action: #selector(toggle))
        menu.addItem(.separator())
        _ = item("Open SaySo…", action: #selector(openWindow))
        _ = item("Enable microphone…", action: #selector(permissions))
        if !LocalTranscriber.modelInstalled { _ = item("Download speech model (1.6 GB)…", action: #selector(downloadModel)) }
        _ = item("Enable automatic paste…", action: #selector(accessibility))
        isolationItem = item("Isolate my voice (lowers music slightly)", action: #selector(toggleIsolation))
        isolationItem.state = voiceIsolation ? .on : .off
        loginItem = item("Open at login (runs in background)", action: #selector(toggleLogin))
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            // Background dictation is the point of SaySo: start at login unless the user turns it off.
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        dockItem = item("Show Dock icon", action: #selector(toggleDock))
        applyDockPolicy()
        _ = item("Copy last transcript", action: #selector(copyLast))
        _ = item("Show last transcript…", action: #selector(showLast))
        menu.addItem(.separator())
        let quitItem = item("Quit SaySo completely", action: #selector(quit))
        quitItem.keyEquivalent = "q"
        status.menu = menu
        previousApp = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.previousApp = app
        }
        audioObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let self = self, let changed = note.object as? AVAudioEngine,
                  changed === self.engine, self.recording else { return }
            trace("audio configuration changed (engine running: %d)", changed.isRunning ? 1 : 0)
            // macOS often posts this right after the input starts; only a stopped engine is a real interruption.
            guard !changed.isRunning else { return }
            self.interruption = "The microphone configuration changed."
            self.stop()
        }
        installShortcut()
        installMainMenu()
        wireModel()
        installGestureMonitors()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.permissionTick() }
        setState(LocalTranscriber.modelInstalled ? readyHint : "Local Whisper model missing")
        transcriber.preload()
        if let seconds = selfTestSeconds {
            trace("self-test recording for %.0f s", seconds)
            toggle()
            guard recording else { trace("self-test could not start recording"); NSApp.terminate(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.stop() }
            return
        }
        if !UserDefaults.standard.bool(forKey: "hasSeenWelcome") {
            openWindow()
            UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
        }
    }

    private func wireModel() {
        model.refreshPermissions()
        model.onToggle = { [weak self] in self?.toggle() }
        model.onCancel = { [weak self] in self?.cancel() }
        model.onPermissions = { [weak self] in self?.permissions() }
        model.onAccessibility = { [weak self] in self?.accessibility() }
        model.onCopyLast = { [weak self] in self?.copyLast() }
        model.onCloseWindow = { NSApp.keyWindow?.performClose(nil) }
        model.onQuit = { [weak self] in self?.quit() }
        model.onDownloadModel = { [weak self] in self?.downloadModel() }
        model.onTriggerChanged = { [weak self] in
            guard let self = self else { return }
            self.gesture = TapGesture()
            if !self.recording && !self.finishing { self.setState(self.readyHint) }
        }
    }

    @objc private func openWindow() { window.show(model) }

    private func permissionTick() {
        model.refreshPermissions()
        // Global key monitors only deliver once Accessibility is granted; reinstall when it flips on.
        if model.axGranted != gestureTrusted { installGestureMonitors() }
    }

    /// Watches modifier taps system-wide (passively — nothing is swallowed). Needs Accessibility.
    private func installGestureMonitors() {
        gestureMonitors.forEach(NSEvent.removeMonitor)
        gestureMonitors = []
        gestureTrusted = AXIsProcessTrusted()
        // Clicks are watched too so ⌘-click never counts as a tap. Nothing is swallowed or recorded.
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handleGesture($0) }) { gestureMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handleGesture($0); return $0 }) { gestureMonitors.append(m) }
    }

    private func handleGesture(_ event: NSEvent) {
        let trigger = model.trigger
        guard trigger.isModifierGesture else { return }
        guard event.type == .flagsChanged, trigger.keyCodes.contains(event.keyCode) else {
            holdTimer?.cancel()
            if gesture.otherInput() == .cancel && recording { cancel() }
            return
        }
        let flag: NSEvent.ModifierFlags = trigger == .fn ? .function : (trigger == .rightOption ? .option : .command)
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        // Is THIS physical key down? The combined ⌘ flag stays set while the other ⌘ key is held.
        let raw = event.modifierFlags.rawValue
        func held(_ code: UInt16) -> Bool? {
            guard let mask = ShortcutTrigger.deviceMask(forKeyCode: code) else { return nil }
            return (raw & mask) != 0
        }
        let keyDown: Bool = held(event.keyCode) ?? flags.contains(flag)
        if keyDown {
            let otherSideHeld = trigger.keyCodes.contains { code in code != event.keyCode && held(code) == true }
            if flags.subtracting(flag).isEmpty && !otherSideHeld {
                gesture.triggerDown(at: event.timestamp)
                holdTimer?.cancel()
                let check = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    if self.gesture.holdCheck(at: ProcessInfo.processInfo.systemUptime, active: self.recording || self.finishing) == .start { self.toggle() }
                }
                holdTimer = check
                DispatchQueue.main.asyncAfter(deadline: .now() + gesture.holdDelay, execute: check)
            } else if gesture.otherInput() == .cancel && recording { cancel() }
            return
        }
        holdTimer?.cancel()
        switch gesture.triggerUp(at: event.timestamp, active: recording) {
        case .start where !recording && !finishing: toggle()
        case .stop where recording: stop()
        default: break
        }
    }

    /// Closing the window never quits: SaySo keeps listening for the shortcut in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !modalVisible && !recording && !finishing else { return false }
        openWindow()
        return false
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { show("Could not change login item", error.localizedDescription) }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        trace("login item status: %d", SMAppService.mainApp.status.rawValue)
    }

    @objc private func toggleIsolation() {
        UserDefaults.standard.set(!voiceIsolation, forKey: "voiceIsolation")
        isolationItem.state = voiceIsolation ? .on : .off
    }

    @objc private func toggleDock() {
        UserDefaults.standard.set(!showInDock, forKey: "showInDock")
        applyDockPolicy()
    }

    private func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        dockItem.state = showInDock ? .on : .off
    }

    private func item(_ title: String, action: Selector?) -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: "")
        value.target = self; menu.addItem(value); return value
    }

    private func installShortcut() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer = pointer else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<DictationApp>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { app.toggle() }
            return noErr
        }, 1, &event, context, &handler)
        let id = EventHotKeyID(signature: OSType(0x50444943), id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if installed != noErr || registered != noErr { setState("Shortcut unavailable — use menu to dictate") }
    }

    private func setState(_ text: String) { stateItem.title = text; model.status = text }
    private func show(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "OK")
        let prior = NSWorkspace.shared.frontmostApplication
        modalVisible = true; NSApp.activate(ignoringOtherApps: true); alert.runModal(); modalVisible = false
        if let prior = prior, !prior.isTerminated, prior.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            prior.activate(options: [])
        }
    }

    @objc private func permissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in DispatchQueue.main.async { self?.permissions() } }; return
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            show("Microphone access is needed", "Enable SaySo in System Settings → Privacy & Security → Microphone, then reopen the app."); return
        }
        model.refreshPermissions()
        setState("Permissions ready · \(model.trigger.startHint) to dictate")
    }

    @objc private func accessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !trusted { show("Enable automatic paste", "Allow SaySo in System Settings → Privacy & Security → Accessibility. Restart the app if macOS asks. Without this permission your transcript is still copied for manual paste.") }
    }

    @objc fileprivate func toggle() {
        trace("toggle (recording: %d, finishing: %d, modal: %d)", recording ? 1 : 0, finishing ? 1 : 0, modalVisible ? 1 : 0)
        guard !modalVisible else { return }
        if recording { stop(); return }
        guard !finishing else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { permissions(); return }
        guard LocalTranscriber.modelInstalled else {
            openWindow(); downloadModel(); return
        }
        let active = NSWorkspace.shared.frontmostApplication
        target = active?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previousApp : active
        transcript = ""; interruption = nil
        engine = AVAudioEngine()
        let id = UUID(); generation = id
        let input = engine.inputNode
        if voiceIsolation {
            // Removes audio this Mac is playing (music) from the mic and suppresses background noise.
            do {
                try input.setVoiceProcessingEnabled(true)
                if #available(macOS 14.0, *) {
                    // Do not turn the user's music down while dictating.
                    input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
                }
            } catch { trace("voice processing unavailable: %@", error.localizedDescription) }
        }
        let format = input.outputFormat(forBus: 0)
        trace("input format: %@ (isolation: %d)", format.description, input.isVoiceProcessingEnabled ? 1 : 0)
        guard format.sampleRate > 0 && format.channelCount > 0, let buffer = AudioCollector(input: format) else { show("No microphone available", "Choose a working input device in System Settings → Sound."); return }
        collector = buffer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] audio, _ in
            buffer.append(audio)
            // Mic level for the pill's waveform: RMS of the first channel, mapped from -50…-10 dB to 0…1.
            guard let samples = audio.floatChannelData?[0], audio.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(audio.frameLength) { sum += samples[i] * samples[i] }
            let db = 20 * log10(max(sqrt(sum / Float(audio.frameLength)), 1e-6))
            let level = min(1, max(0, (db + 50) / 40))
            DispatchQueue.main.async { self?.model.level = level }
        }
        tapInstalled = true
        do { engine.prepare(); try engine.start() }
        catch { cleanup(); show("Could not start recording", error.localizedDescription); return }
        recording = true; finishing = false; startedAt = Date()
        toggleItem.title = "Stop & paste"; status.button?.title = "● Recording"
        setState("Listening · \(model.trigger.stopHint) to finish")
        model.phase = .listening; pill.show(model)
        // Keep memory bounded: stop and transcribe after ten minutes.
        let limit = DispatchWorkItem { [weak self] in self?.stop() }
        timeout = limit; DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: limit)
    }

    private func stop() {
        guard recording else { return }
        recording = false; finishing = true
        timeout?.cancel(); engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        setState("Transcribing on this Mac…"); status.button?.title = "… SaySo"
        model.phase = .finishing
        let id = generation, samples = collector?.take() ?? []
        collector = nil
        trace("transcribing %d samples locally", samples.count)
        guard samples.count >= 8_000 else { complete(id: id, error: nil); return }
        transcriber.transcribe(samples) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let text): self.transcript = text; self.complete(id: id, error: nil)
            case .failure(let error): self.complete(id: id, error: error.localizedDescription)
            }
        }
    }

    private func cleanup() {
        timeout?.cancel(); timeout = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        collector = nil
        recording = false; finishing = false
        toggleItem.title = "Start dictation"; status.button?.title = "SaySo"
        model.phase = .idle; model.level = 0; pill.hide()
    }

    /// ✕ in the pill: discard everything, paste nothing.
    private func cancel() {
        guard recording || finishing else { return }
        generation = UUID(); cleanup()
        setState("Cancelled · nothing pasted")
    }

    private func complete(id: UUID, error: String?) {
        guard generation == id, recording || finishing else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = interruption ?? (recording ? "Recording stopped unexpectedly." : nil) ?? error
        trace("complete (chars: %d, reason: %@, error: %@)", transcript.count, reason ?? "none", error ?? "none")
        generation = UUID(); let completedGeneration = generation
        cleanup()
        if selfTestSeconds != nil {
            trace("self-test transcript: %@", text.isEmpty ? "(empty)" : text)
            NSApp.terminate(nil); return
        }
        guard !text.isEmpty else { setState(reason == nil ? "No speech detected" : "No transcript · try again or check microphone"); return }
        lastTranscript = text
        model.record(words: text.split(whereSeparator: { $0.isWhitespace }).count, seconds: Date().timeIntervalSince(startedAt))
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        if let reason = reason { setState("\(reason) Transcript copied; paste manually."); return }
        trace("paste check (ax: %d, target: %@, front: %@)", AXIsProcessTrusted() ? 1 : 0, target?.bundleIdentifier ?? "none", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")
        guard AXIsProcessTrusted(), let destination = target, !destination.isTerminated,
              destination.processIdentifier != ProcessInfo.processInfo.processIdentifier else { setState("Transcript copied · ⌘V to paste"); return }
        pasteWhenReleased(text: text, process: destination.processIdentifier, generation: completedGeneration, deadline: Date().addingTimeInterval(2))
    }

    private func pasteWhenReleased(text: String, process: pid_t, generation id: UUID, deadline: Date) {
        guard generation == id, !recording && !finishing else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == process,
              NSPasteboard.general.string(forType: .string) == text else {
            trace("paste skipped: focus or clipboard changed (front: %@)", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")
            setState("Focus or clipboard changed · paste manually"); return
        }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        if !flags.intersection(modifiers).isEmpty {
            guard Date() < deadline else { trace("paste skipped: modifiers held (flags: %llu)", flags.rawValue); setState("Modifiers still held · transcript copied for manual paste"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.pasteWhenReleased(text: text, process: process, generation: id, deadline: deadline)
            }
            return
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            setState("Transcript copied · paste manually"); return
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        trace("paste: posted Cmd-V")
        setState("Paste requested · copy last transcript if needed")
    }

    @objc private func copyLast() {
        guard !lastTranscript.isEmpty else { setState("No transcript in this session yet"); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lastTranscript, forType: .string)
        setState("Last transcript copied")
    }
    @objc private func showLast() { show("Last transcript", lastTranscript.isEmpty ? "No transcript in this session yet." : lastTranscript) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func downloadModel() {
        guard model.downloadProgress == nil else { return }
        model.downloadProgress = 0
        setState("Downloading local Whisper model…")
        LocalTranscriber.downloadModels(progress: { [weak self] p in
            self?.model.downloadProgress = p
            self?.stateItem.title = "Downloading model… \(Int(p * 100))%"
        }, completion: { [weak self] error in
            guard let self = self else { return }
            self.model.downloadProgress = nil
            self.model.refreshPermissions()
            if let error = error { self.show("Model download failed", error.localizedDescription); self.setState("Local Whisper model missing"); return }
            self.transcriber.preload()
            self.setState(self.readyHint)
        })
    }

    /// ⌘W closes the window (SaySo keeps running in the menu bar); ⌘Q quits completely.
    private func installMainMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu(title: "SaySo")
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: "Quit SaySo", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appItem.submenu = appMenu; main.addItem(appItem)
        NSApp.mainMenu = main
    }
    func applicationWillTerminate(_ notification: Notification) {
        generation = UUID(); cleanup()
        if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
        if let handler = handler { RemoveEventHandler(handler) }
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let observer = audioObserver { NotificationCenter.default.removeObserver(observer) }
        gestureMonitors.forEach(NSEvent.removeMonitor)
        transcriber.shutdown()
    }
}

/// Diagnostics (never transcript text, except in --self-test) to ~/Library/Logs/Sayso.log and stderr.
func trace(_ format: String, _ args: CVarArg...) {
    let line = "\(Date()) SaySo: " + String(format: format, arguments: args) + "\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Sayso.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

if let i = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > i + 1 {
    exit(MainActor.assumeIsolated { PreviewRenderer.run(to: CommandLine.arguments[i + 1]) })
}

let app = NSApplication.shared
let delegate = DictationApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
