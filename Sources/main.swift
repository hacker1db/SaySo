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
    private var window: NSWindow?
    private var statusLabel = NSTextField(labelWithString: "")
    private var startButton = NSButton()
    private var micLabel = NSTextField(labelWithString: "")
    private var pasteLabel = NSTextField(labelWithString: "")
    private var cloudBox = NSButton()
    private var dockBox = NSButton()
    private var history = NSTextView()
    private var transcripts: [String] = []
    private var showInDock: Bool { UserDefaults.standard.bool(forKey: "showInDock") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Sayso"
        menu.autoenablesItems = false
        stateItem = item("Ready · ⌃⌥Space to dictate", action: nil)
        stateItem.isEnabled = false
        toggleItem = item("Start dictation", action: #selector(toggle))
        menu.addItem(.separator())
        _ = item("Open Sayso…", action: #selector(showWindow))
        _ = item("How to use Sayso…", action: #selector(showWelcome))
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
            // macOS commonly posts a configuration change right after the input starts; only a stopped engine is a real interruption.
            NSLog("Sayso: audio configuration changed (engine running: %d)", changed.isRunning ? 1 : 0)
            guard !changed.isRunning else { return }
            self.interruption = "The microphone configuration changed."
            self.stop()
        }
        installShortcut()
        UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
        showWindow()
    }

    func applicationDidBecomeActive(_ notification: Notification) { refreshWindow() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !modalVisible else { return false }
        showWindow()
        return false
    }

    @objc private func showWelcome() {
        show("Sayso is running", "Sayso lives in your menu bar; choose Show Dock icon from its menu if you also want it in the Dock. Use the Sayso window (click the Dock icon or choose Open Sayso… from the menu bar) to enable microphone and speech permissions, then press Control–Option–Space to start or stop dictation. Enable automatic paste from the menu if desired; otherwise paste the copied transcript yourself. Recognition stays on-device unless you explicitly allow Apple cloud recognition.")
    }

    @objc private func toggleDock() {
        UserDefaults.standard.set(!showInDock, forKey: "showInDock")
        applyDockPolicy()
    }

    private func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        dockItem.state = showInDock ? .on : .off; refreshWindow()
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

    private func setState(_ text: String) { stateItem.title = text; refreshWindow() }

    @objc private func showWindow() {
        if window == nil { buildWindow() }
        refreshWindow()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Sayso"; w.isReleasedWhenClosed = false; w.minSize = NSSize(width: 400, height: 480)
        func label(_ text: String, size: CGFloat = 13, bold: Bool = false, grey: Bool = false) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
            if grey { l.textColor = .secondaryLabelColor }
            return l
        }
        func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
        func row(_ views: [NSView]) -> NSStackView { let r = NSStackView(views: views); r.orientation = .horizontal; r.spacing = 8; return r }
        statusLabel.font = .systemFont(ofSize: 14); statusLabel.textColor = .secondaryLabelColor
        startButton = button("Start dictation", #selector(toggle))
        startButton.bezelStyle = .rounded; startButton.controlSize = .large; startButton.keyEquivalent = "\r"
        cloudBox = NSButton(checkboxWithTitle: "Allow Apple cloud recognition", target: self, action: #selector(toggleCloud))
        dockBox = NSButton(checkboxWithTitle: "Show Dock icon", target: self, action: #selector(toggleDock))
        history.isEditable = false; history.font = .systemFont(ofSize: 13); history.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView(); scroll.documentView = history; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        history.autoresizingMask = [.width]; history.isVerticallyResizable = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let stack = NSStackView(views: [
            label("Sayso", size: 24, bold: true), statusLabel,
            row([startButton, label("or press ⌃⌥Space (Control–Option–Space) in any app", grey: true)]),
            label("Setup", size: 15, bold: true),
            row([micLabel, button("Enable…", #selector(permissions))]),
            row([pasteLabel, button("Enable…", #selector(accessibility))]),
            label("Options", size: 15, bold: true), cloudBox, dockBox,
            label("Transcripts this session", size: 15, bold: true), scroll,
            row([button("Copy last transcript", #selector(copyLast)), button("How to use Sayso…", #selector(showWelcome))]),
        ])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); content.addSubview(stack); w.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20), scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20),
        ])
        w.center(); window = w
    }

    private func refreshWindow() {
        guard window != nil else { return }
        statusLabel.stringValue = stateItem.title
        startButton.title = recording ? "Stop & paste" : (finishing ? "Finishing…" : "Start dictation")
        startButton.isEnabled = !finishing
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && SFSpeechRecognizer.authorizationStatus() == .authorized
        micLabel.stringValue = micOK ? "✅ Microphone & speech recognition" : "⚠️ Microphone & speech recognition not enabled"
        pasteLabel.stringValue = AXIsProcessTrusted() ? "✅ Automatic paste (Accessibility)" : "⚠️ Automatic paste off (transcripts are still copied)"
        cloudBox.state = cloudAllowed ? .on : .off; cloudBox.isEnabled = !recording && !finishing
        dockBox.state = showInDock ? .on : .off
        history.string = transcripts.isEmpty ? "No transcripts yet. They're kept only until you quit Sayso." : transcripts.reversed().joined(separator: "\n\n")
    }
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
        setState("Permissions ready · ⌃⌥Space to dictate")
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
        cloudItem.state = cloudAllowed ? .on : .off; refreshWindow()
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
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { audio, _ in buffer.append(audio) }
        tapInstalled = true
        do { engine.prepare(); try engine.start() }
        catch { cleanup(); show("Could not start recording", error.localizedDescription); return }
        recording = true; finishing = false
        toggleItem.title = "Stop & paste"; status.button?.title = "● Recording"
        setState("Listening · ⌃⌥Space to finish")
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
        toggleItem.title = "Start dictation"; cloudItem.isEnabled = true; status.button?.title = "Sayso"; refreshWindow()
    }

    private func complete(id: UUID, error: String?) {
        guard generation == id, recording || finishing else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = interruption ?? (recording ? "Speech recognition stopped unexpectedly." : nil) ?? error
        NSLog("Sayso: finished (chars: %d, reason: %@)", transcript.count, reason ?? "none")
        generation = UUID(); let completedGeneration = generation
        cleanup()
        guard !text.isEmpty else { setState(reason == nil ? "No speech detected" : "No transcript · try again or check microphone"); return }
        lastTranscript = text; transcripts.append(text); refreshWindow()
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
    }
}

let app = NSApplication.shared
let delegate = DictationApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
