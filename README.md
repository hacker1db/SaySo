# Sayso for Mac

A small menu-bar dictation app. **Double-tap ⌘** anywhere to start talking — no holding — and **tap ⌘ once** to finish and paste into the active app. A pill at the bottom of the screen shows a live waveform with ✕ (cancel, nothing pasted) and ✓ (finish and paste). **Control–Option–Space** always works as a backup. No paid account or API key is required.

## Shortcut

Choose the key in **Sayso › Shortcut**: Command (either side, default), Right ⌘, Left ⌘, Right ⌥, fn/Globe, or Control–Option–Space only. A tap counts only when the key is pressed alone and released within 0.35 s; the second tap must follow within 0.4 s. Any other key, modifier, the other ⌘ key, or a mouse click during the press cancels the gesture, so ⌘C, ⌘V and ⌘-click never start or stop dictation. If you pick fn, first change macOS Dictation's “Press fn twice” shortcut, or both will start. Key gestures are observed passively (nothing is swallowed) and need the same Accessibility permission as auto-paste; without it, use Control–Option–Space.

## Build and use

Requires macOS 13+ and Xcode Command Line Tools. On your Mac:

```sh
xcode-select --install # only if not already installed
./scripts/build.sh
cp -R "build/Sayso.app" /Applications/
open "/Applications/Sayso.app"
```

1. Install whisper.cpp (`brew install whisper-cpp`) and download the model: `mkdir -p ~/Library/Application\ Support/Sayso/models && curl -L -o ~/Library/Application\ Support/Sayso/models/ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin`
1. From the **Sayso** menu, select **Enable microphone…** and grant access.
2. Select **Enable automatic paste…**, grant Accessibility access in System Settings, then restart the app if required.
3. Put the cursor in a normal text field in Notes, **double-tap ⌘**, speak, then **tap ⌘** (or press ⌃⌥Space before and after).
4. Without Accessibility access, the transcript is copied: press **⌘V** yourself. **Copy last transcript** recovers the latest result.

Copy/install before granting permissions; changing the bundle path or rebuilding an ad hoc signed app can make macOS require permission again. Set `SIGNING_IDENTITY` when building if you have a Developer ID certificate. This is a local build, not a notarized distribution.

## Speech and privacy

Sayso transcribes **only on this Mac** with [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (Metal GPU) and the `ggml-large-v3-turbo` model in `~/Library/Application Support/Sayso/models`. It does not use Apple Speech or any cloud service. Recognition is English (`en`).

**Isolate my voice (lowers music slightly)** is off by default. When on, Apple voice processing cancels audio this Mac is playing and suppresses background noise, but macOS always lowers other audio somewhat while it runs (Sayso requests the minimum). Silero VAD (`ggml-silero-v5.1.2.bin`, same folder, from https://huggingface.co/ggml-org/whisper-vad) drops non-speech before Whisper so silence is not turned into invented text. Music in the room from another device is reduced but not removed; headphones avoid the problem entirely.

Audio is kept in memory only while you dictate and is discarded after transcription. The last transcript stays in memory until quitting and on the system clipboard until replaced; universal clipboard or clipboard managers can retain it. The app does not read surrounding text or take screenshots. Recording stops and transcribes automatically after ten minutes.

## Limits and verification

- No LLM cleanup, personal dictionary, command mode, meetings, or persistent recording history.
- Automatic paste uses the clipboard and Command-V. It waits up to two seconds for Control/Option/Shift/Command to be released, then only requests paste if the original application still has focus and the clipboard has not changed. Microphone changes, early recognition completion, errors and time limits recover the transcript without automatic paste. Clipboard recovery remains available if an app rejects it. Switching fields inside one app cannot be detected; stop dictation before changing fields. Do not dictate into password fields.
- Global shortcut conflicts are reported in the menu. The home window (menu › **Open Sayso…**) shows permissions, the shortcut picker, privacy settings and stats. Stats are three counters (words, recording minutes, day streak) in UserDefaults; no transcript text is stored.
- `scripts/test.sh` runs the tap-gesture checks; `Sayso --render-previews <dir>` renders the window and pill to PNG without touching the desktop.
- This source was authored on Linux. **GitHub’s macOS CI compiles and code-signature-checks the app. Live permission dialogs, audio recognition, shortcut delivery, and paste have not been verified on a Mac yet.** Do not treat it as a tested release until the acceptance checks below pass.
- Portable checks: `bash -n scripts/build.sh`; Python’s `plistlib` validates the purpose strings, executable name and deployment target. These checks do not compile Swift.

## Mac acceptance check

Build and verify the code signature; test microphone denial and approval; test dictation with networking off; test with the model file missing; dictate into Notes and a browser text field; verify no auto-paste after switching apps; verify copy-last recovery; finish an empty recording; test timeout and microphone disconnect. Actual Mac results must be recorded before claiming this works end-to-end.

This independently written app follows the documented dictation workflow. It does not contain Wispr Flow code or model assets, and does not reproduce its proprietary transcription quality.
