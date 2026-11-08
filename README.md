# Personal Dictation for Mac

A small menu-bar dictation app: **Control–Option–Space** starts listening; the same shortcut finishes and pastes the transcript into the active app. The menu also starts/stops dictation. No paid account or API key is required.

## Build and use

Requires macOS 13+ and Xcode Command Line Tools. On your Mac:

```sh
xcode-select --install # only if not already installed
./scripts/build.sh
cp -R "build/Personal Dictation.app" /Applications/
open "/Applications/Personal Dictation.app"
```

1. From the **Dictate** menu, select **Enable microphone & speech…** and grant both permissions.
2. Select **Enable automatic paste…**, grant Accessibility access in System Settings, then restart the app if required.
3. Put the cursor in a normal text field in Notes, press **⌃⌥Space**, speak, then press **⌃⌥Space** again.
4. Without Accessibility access, the transcript is copied: press **⌘V** yourself. **Copy last transcript** recovers the latest result.

Copy/install before granting permissions; changing the bundle path or rebuilding an ad hoc signed app can make macOS require permission again. Set `SIGNING_IDENTITY` when building if you have a Developer ID certificate. This is a local build, not a notarized distribution.

## Speech and privacy

Apple Speech uses your current system locale. **On-device recognition is required by default.** If that language/device cannot recognize locally, the app refuses to record until you explicitly opt into **Allow Apple cloud recognition**. It prefers on-device recognition even when cloud use is allowed. Language assets and availability depend on your Mac and macOS installation.

Audio goes directly to the recognition request and is not saved by this app. The last transcript stays in memory until quitting and on the system clipboard until replaced; universal clipboard or clipboard managers can retain it. The app does not read surrounding text or take screenshots. With cloud mode enabled, Apple may process your audio remotely. See [Apple’s speech permission documentation](https://developer.apple.com/documentation/Speech/asking-permission-to-use-speech-recognition) and [on-device support](https://developer.apple.com/documentation/Speech/SFSpeechRecognizer/supportsOnDeviceRecognition).

## Limits and verification

- A session stops after 55 seconds and copies the partial result for manual paste to fit the legacy Apple Speech service’s bounded sessions; this is not Wispr’s longer-session cloud engine.
- No LLM cleanup, personal dictionary, command mode, meetings, or persistent recording history.
- Automatic paste uses the clipboard and Command-V. It waits up to two seconds for Control/Option/Shift/Command to be released, then only requests paste if the original application still has focus and the clipboard has not changed. Microphone changes, early recognition completion, errors and time limits recover the transcript without automatic paste. Clipboard recovery remains available if an app rejects it. Switching fields inside one app cannot be detected; stop dictation before changing fields. Do not dictate into password fields.
- Global shortcut conflicts are reported in the menu. There is no shortcut editor yet.
- This source was authored on Linux. **GitHub’s macOS CI compiles and code-signature-checks the app. Live permission dialogs, audio recognition, shortcut delivery, and paste have not been verified on a Mac yet.** Do not treat it as a tested release until the acceptance checks below pass.
- Portable checks: `bash -n scripts/build.sh`; Python’s `plistlib` validates the purpose strings, executable name and deployment target. These checks do not compile Swift.

## Mac acceptance check

Build and verify the code signature; test microphone/speech denial and approval; test on-device dictation with networking off for a supported language; test cloud opt-in if local recognition is unavailable; dictate into Notes and a browser text field; verify no auto-paste after switching apps; verify copy-last recovery; finish an empty recording; test timeout and microphone disconnect. Actual Mac results must be recorded before claiming this works end-to-end.

This independently written app follows the documented dictation workflow. It does not contain Wispr Flow code or model assets, and does not reproduce its proprietary transcription quality.
