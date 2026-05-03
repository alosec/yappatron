# Yappatron iOS

Native iPhone companion app for Yappatron dictation.

## What Ships Here

- `YappatronIOS` iOS app target
  - SwiftUI recorder UI
  - Deepgram Nova-3 realtime WebSocket transcription
  - API key storage in Keychain
  - Background audio mode declaration
  - Latest transcript sync through an App Group
  - Copy and share actions
- `YappatronKeyboard` custom keyboard extension target
  - Reads the latest synced transcript
  - Inserts text into the active iOS text field with `textDocumentProxy.insertText`
  - Optional one-shot auto-insert when the keyboard opens

## Current Type-Anywhere Model

iOS does not allow macOS-style global keystroke injection. The supported path is:

1. Start recording in the Yappatron app.
2. Switch to the destination app while the audio session is active.
3. Use the Yappatron keyboard to insert the latest transcript into the current text field.

The app declares `UIBackgroundModes = audio`, which is the same family of workaround used by many iOS dictation companions. iOS can still suspend or terminate the app, so this should be tested on-device under real switching patterns.

## Requirements

- Full Xcode installed and selected
- iOS 17+ device or simulator
- Apple signing team for device builds
- App Group capability for both targets:
  - `group.com.yappatron.shared`
- Bundle IDs:
  - App: `com.yappatron.ios`
  - Keyboard: `com.yappatron.ios.keyboard`

## Build And Run

Open:

```bash
open packages/ios/YappatronIOS/YappatronIOS.xcodeproj
```

In Xcode:

1. Select the `YappatronIOS` project.
2. Set your Team on both `YappatronIOS` and `YappatronKeyboard`.
3. Add the App Groups capability to both targets.
4. Register and enable `group.com.yappatron.shared`.
5. Run `YappatronIOS` on an iPhone.
6. On iPhone, enable the keyboard in Settings > General > Keyboard > Keyboards, then turn on Allow Full Access for Yappatron Keyboard.

## TestFlight

After a successful device build:

1. Increment build number.
2. Select Any iOS Device.
3. Product > Archive.
4. Distribute App > App Store Connect.
5. Upload for TestFlight.

External testing still requires Beta App Review.
