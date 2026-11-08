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
    private let engine = AVAudioEngine()
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
    private var cloudAllowed: Bool { UserDefaults.standard.bool(forKey: "allowAppleCloud") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Dictate"
        stateItem = item("Ready · ⌃⌥Space to dictate", action: nil)
        toggleItem = item("Start dictation", action: #selector(toggle))
        menu.addItem(.separator())
        _ = item("Enable microphone & speech…", action: #selector(permissions))
        _ = item("Enable automatic paste…", action: #selector(accessibility))
        cloudItem = item("Allow Apple cloud recognition", action: #selector(toggleCloud))
        cloudItem.state = cloudAllowed ? .on : .off
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
        installShortcut()
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

    private func setState(_ text: String) { stateItem.title = text }
    private func show(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "OK"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }

    @objc private func permissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in DispatchQueue.main.async { self?.permissions() } }; return
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            show("Microphone access is needed", "Enable Personal Dictation in System Settings → Privacy & Security → Microphone, then reopen the app."); return
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in DispatchQueue.main.async { self?.permissions() } }; return
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            show("Speech recognition access is needed", "Enable Personal Dictation in System Settings → Privacy & Security → Speech Recognition."); return
        }
        setState("Permissions ready · ⌃⌥Space to dictate")
    }

    @objc private func accessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !trusted { show("Enable automatic paste", "Allow Personal Dictation in System Settings → Privacy & Security → Accessibility. Restart the app if macOS asks. Without this permission your transcript is still copied for manual paste.") }
    }

    @objc private func toggleCloud() {
        guard !recording && !finishing else { return }
        if !cloudAllowed {
            let alert = NSAlert(); alert.messageText = "Allow Apple cloud speech recognition?"
            alert.informativeText = "If local recognition is unavailable, your microphone audio may be sent to Apple for transcription. Leave this disabled to require on-device recognition."
            alert.addButton(withTitle: "Allow"); alert.addButton(withTitle: "Keep on-device only")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        UserDefaults.standard.set(!cloudAllowed, forKey: "allowAppleCloud")
        cloudItem.state = cloudAllowed ? .on : .off
    }

    @objc fileprivate func toggle() {
        if recording { stop(); return }
        guard !finishing else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              SFSpeechRecognizer.authorizationStatus() == .authorized else { permissions(); return }
        let locale = Locale(identifier: Locale.current.identifier)
        guard let speech = SFSpeechRecognizer(locale: locale) else { show("Language unavailable", "Apple Speech does not support your current system language (\(locale.identifier))."); return }
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
        request = buffer; recognizer = speech; transcript = ""
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
                if result?.isFinal == true { self.complete(id: id, error: nil) }
                else if let error = error { self.complete(id: id, error: error.localizedDescription) }
            }
        }
        // Apple’s legacy recognition service has bounded sessions. Finish before the usual one-minute limit.
        let limit = DispatchWorkItem { [weak self] in self?.stop() }
        timeout = limit; DispatchQueue.main.asyncAfter(deadline: .now() + 55, execute: limit)
    }

    private func stop() {
        guard recording else { return }
        recording = false; finishing = true
        timeout?.cancel(); engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); setState("Finishing transcription…"); status.button?.title = "… Dictate"
        let id = generation
        let deadline = DispatchWorkItem { [weak self] in self?.complete(id: id, error: "Speech recognition did not finalize. The partial transcript was copied; it was not pasted automatically.") }
        timeout = deadline; DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
    }

    private func cleanup() {
        timeout?.cancel(); timeout = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); request = nil
        task?.cancel(); task = nil; recognizer = nil
        recording = false; finishing = false
        toggleItem.title = "Start dictation"; cloudItem.isEnabled = true; status.button?.title = "Dictate"
    }

    private func complete(id: UUID, error: String?) {
        guard generation == id, recording || finishing else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        generation = UUID(); cleanup()
        guard !text.isEmpty else { setState(error == nil ? "No speech detected" : "Recognition failed — try again"); if let error = error { show("Recognition failed", error) }; return }
        lastTranscript = text
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        if let error = error { setState("Partial transcript copied — paste manually"); show("Transcript recovered", error); return }
        guard AXIsProcessTrusted(), let destination = target, !destination.isTerminated,
              destination.processIdentifier != ProcessInfo.processInfo.processIdentifier else { setState("Transcript copied · ⌘V to paste"); return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier else {
            setState("Focus changed · transcript copied for manual paste"); return
        }
        // Never reactivate or paste into a different app if the user changed focus while speaking.
        let pasteText = text, pasteTarget = destination.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pasteTarget,
                  NSPasteboard.general.string(forType: .string) == pasteText,
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { self?.setState("Transcript copied · paste manually"); return }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            self?.setState("Paste requested · copy last transcript if needed")
        }
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
    }
}

let app = NSApplication.shared
let delegate = DictationApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
