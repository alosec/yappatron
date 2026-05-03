# Yappatron iOS

Native iPhone companion app for Yappatron dictation.

## What Ships Here

- `YappatronIOS` iOS app target
  - SwiftUI recorder UI
  - Local on-device speech recognition mode
  - Deepgram Nova-3 realtime WebSocket transcription
  - API key storage in Keychain
  - Background audio mode declaration
  - Latest transcript handoff through a Yappatron-tagged pasteboard item
  - Copy and share actions
- `YappatronKeyboard` custom keyboard extension target
  - Reads the latest Yappatron-tagged pasteboard transcript
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
- Apple Account in Xcode for free Personal Team device builds
- iPhone Developer Mode enabled for direct install
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
2. Set your Personal Team on both `YappatronIOS` and `YappatronKeyboard`.
3. Run `YappatronIOS` on an iPhone.
4. On iPhone, enable the keyboard in Settings > General > Keyboard > Keyboards, then turn on Allow Full Access for Yappatron Keyboard.

The app defaults to Local mode, which uses Apple's on-device speech recognition and does not require a Deepgram API key. Deepgram remains available from the Mode picker.

## TestFlight

After a successful device build:

1. Increment build number.
2. Select Any iOS Device.
3. Product > Archive.
4. Distribute App > App Store Connect.
5. Upload for TestFlight.

External testing still requires Beta App Review.
