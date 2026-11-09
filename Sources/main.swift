import AppKit
import AVFoundation
import Speech
import Carbon.HIToolbox
import ApplicationServices

final class DictationApp: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private let menu = NSMenu()
    private var toggleItem: NSMenuItem!
    private var stateItem: NSMenuItem!
    private var cloudItem: NSMenuItem!
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
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
    private var cloudAllowed: Bool { UserDefaults.standard.bool(forKey: "allowAppleCloud") }
    private var dockItem: NSMenuItem!
    private var showInDock: Bool { UserDefaults.standard.bool(forKey: "showInDock") }
    private let model = AppModel()
    private let pill = PillController()
    private let window = MainWindowController()
    private var gesture = TapGesture()
    private var gestureMonitors: [Any] = []
    private var gestureTrusted = false
    private var permissionTimer: Timer?
    private var startedAt = Date()
    private var readyHint: String { "Ready · \(model.trigger.startHint) to dictate" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Sayso"
        menu.autoenablesItems = false
        stateItem = item(readyHint, action: nil)
        stateItem.isEnabled = false
        toggleItem = item("Start dictation", action: #selector(toggle))
        menu.addItem(.separator())
        _ = item("Open Sayso…", action: #selector(openWindow))
        _ = item("Enable microphone & speech…", action: #selector(permissions))
        _ = item("Enable automatic paste…", action: #selector(accessibility))
        cloudItem = item("Allow Apple cloud recognition", action: #selector(toggleCloud))
        cloudItem.state = cloudAllowed ? .on : .off
        dockItem = item("Show Dock icon", action: #selector(toggleDock))
        applyDockPolicy()
        _ = item("Copy last transcript", action: #selector(copyLast))
        _ = item("Show last transcript…", action: #selector(showLast))
        menu.addItem(.separator())
        _ = item("Quit", action: #selector(quit))
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
            self.interruption = "The microphone configuration changed."
            self.stop()
        }
        installShortcut()
        wireModel()
        installGestureMonitors()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.permissionTick() }
        setState(readyHint)
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
        model.onToggleCloud = { [weak self] in self?.toggleCloud() }
        model.onCopyLast = { [weak self] in self?.copyLast() }
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
        guard event.type == .flagsChanged else { gesture.otherInput(); return }
        guard trigger.keyCodes.contains(event.keyCode) else { gesture.otherInput(); return }
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
            if flags.subtracting(flag).isEmpty && !otherSideHeld { gesture.triggerDown(at: event.timestamp) } else { gesture.otherInput() }
            return
        }
        switch gesture.triggerUp(at: event.timestamp, active: recording) {
        case .start where !recording && !finishing: toggle()
        case .stop where recording: stop()
        default: break
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !modalVisible && !recording && !finishing else { return false }
        openWindow()
        return false
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
            show("Microphone access is needed", "Enable Sayso in System Settings → Privacy & Security → Microphone, then reopen the app."); return
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in DispatchQueue.main.async { self?.permissions() } }; return
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            show("Speech recognition access is needed", "Enable Sayso in System Settings → Privacy & Security → Speech Recognition."); return
        }
        model.refreshPermissions()
        setState("Permissions ready · \(model.trigger.startHint) to dictate")
    }

    @objc private func accessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !trusted { show("Enable automatic paste", "Allow Sayso in System Settings → Privacy & Security → Accessibility. Restart the app if macOS asks. Without this permission your transcript is still copied for manual paste.") }
    }

    @objc private func toggleCloud() {
        guard !recording && !finishing else { return }
        if !cloudAllowed {
            let alert = NSAlert(); alert.messageText = "Allow Apple cloud speech recognition?"
            alert.informativeText = "If local recognition is unavailable, your microphone audio may be sent to Apple for transcription. Leave this disabled to require on-device recognition."
            alert.addButton(withTitle: "Allow"); alert.addButton(withTitle: "Keep on-device only")
            modalVisible = true
            let response = alert.runModal()
            modalVisible = false
            guard response == .alertFirstButtonReturn else { return }
        }
        guard !recording && !finishing else { return }
        UserDefaults.standard.set(!cloudAllowed, forKey: "allowAppleCloud")
        cloudItem.state = cloudAllowed ? .on : .off
        model.cloudAllowed = cloudAllowed
    }

    @objc fileprivate func toggle() {
        guard !modalVisible else { return }
        if recording { stop(); return }
        guard !finishing else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              SFSpeechRecognizer.authorizationStatus() == .authorized else { permissions(); return }
        let locales = [Locale.current.identifier] + Locale.preferredLanguages
        guard let speech = locales.lazy.compactMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) }).first else {
            show("Language unavailable", "Apple Speech does not support your preferred system languages."); return
        }
        if !speech.supportsOnDeviceRecognition && !cloudAllowed {
            show("On-device recognition unavailable", "This Mac or language does not support Apple’s on-device recognizer. Download the language assets if available, or explicitly enable Apple cloud recognition from the menu."); return
        }
        guard speech.isAvailable else { show("Speech recognition unavailable", "Apple Speech is temporarily unavailable. Check your language downloads or network if cloud recognition is enabled."); return }
        let active = NSWorkspace.shared.frontmostApplication
        target = active?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previousApp : active
        let buffer = SFSpeechAudioBufferRecognitionRequest()
        buffer.shouldReportPartialResults = true
        buffer.requiresOnDeviceRecognition = speech.supportsOnDeviceRecognition
        if #available(macOS 13.0, *) { buffer.addsPunctuation = true }
        request = buffer; recognizer = speech; transcript = ""; interruption = nil
        engine = AVAudioEngine()
        let id = UUID(); generation = id
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else { request = nil; show("No microphone available", "Choose a working input device in System Settings → Sound."); return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] audio, _ in
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
        cloudItem.isEnabled = false
        task = speech.recognitionTask(with: buffer) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.generation == id else { return }
                if let result = result { self.transcript = result.bestTranscription.formattedString }
                if result?.isFinal == true {
                    if self.recording { self.interruption = "Speech recognition ended before you stopped." }
                    self.complete(id: id, error: nil)
                } else if let error = error { self.complete(id: id, error: error.localizedDescription) }
            }
        }
        // Apple’s legacy recognition service has bounded sessions. Finish before the usual one-minute limit.
        let limit = DispatchWorkItem { [weak self] in
            self?.interruption = "The 55-second session limit was reached."
            self?.stop()
        }
        timeout = limit; DispatchQueue.main.asyncAfter(deadline: .now() + 55, execute: limit)
    }

    private func stop() {
        guard recording else { return }
        recording = false; finishing = true
        timeout?.cancel(); engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); setState("Finishing transcription…"); status.button?.title = "… Sayso"
        model.phase = .finishing
        let id = generation
        let deadline = DispatchWorkItem { [weak self] in self?.complete(id: id, error: "Speech recognition did not finalize in time.") }
        timeout = deadline; DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
    }

    private func cleanup() {
        timeout?.cancel(); timeout = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); request = nil
        task?.cancel(); task = nil; recognizer = nil
        recording = false; finishing = false
        toggleItem.title = "Start dictation"; cloudItem.isEnabled = true; status.button?.title = "Sayso"
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
        let reason = interruption ?? (recording ? "Speech recognition stopped unexpectedly." : nil) ?? error
        generation = UUID(); let completedGeneration = generation
        cleanup()
        guard !text.isEmpty else { setState(reason == nil ? "No speech detected" : "No transcript · try again or check microphone"); return }
        lastTranscript = text
        model.record(words: text.split(whereSeparator: { $0.isWhitespace }).count, seconds: Date().timeIntervalSince(startedAt))
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        if let reason = reason { setState("\(reason) Transcript copied; paste manually."); return }
        guard AXIsProcessTrusted(), let destination = target, !destination.isTerminated,
              destination.processIdentifier != ProcessInfo.processInfo.processIdentifier else { setState("Transcript copied · ⌘V to paste"); return }
        pasteWhenReleased(text: text, process: destination.processIdentifier, generation: completedGeneration, deadline: Date().addingTimeInterval(2))
    }

    private func pasteWhenReleased(text: String, process: pid_t, generation id: UUID, deadline: Date) {
        guard generation == id, !recording && !finishing else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == process,
              NSPasteboard.general.string(forType: .string) == text else {
            setState("Focus or clipboard changed · paste manually"); return
        }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        if !flags.intersection(modifiers).isEmpty {
            guard Date() < deadline else { setState("Modifiers still held · transcript copied for manual paste"); return }
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
        setState("Paste requested · copy last transcript if needed")
    }

    @objc private func copyLast() {
        guard !lastTranscript.isEmpty else { setState("No transcript in this session yet"); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lastTranscript, forType: .string)
        setState("Last transcript copied")
    }
    @objc private func showLast() { show("Last transcript", lastTranscript.isEmpty ? "No transcript in this session yet." : lastTranscript) }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        generation = UUID(); cleanup()
        if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
        if let handler = handler { RemoveEventHandler(handler) }
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let observer = audioObserver { NotificationCenter.default.removeObserver(observer) }
        gestureMonitors.forEach(NSEvent.removeMonitor)
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > i + 1 {
    exit(MainActor.assumeIsolated { PreviewRenderer.run(to: CommandLine.arguments[i + 1]) })
}

let app = NSApplication.shared
let delegate = DictationApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
