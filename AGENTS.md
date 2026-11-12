# Instructions for coding agents

This file is for AI coding agents working in this repo, most often to install InstTuner on
someone's iPhone. People can follow it too; the README has the same install steps for Xcode's
interface.

## Install InstTuner on the user's iPhone

InstTuner isn't on the App Store, so it has to be built and signed with the user's own Apple
Account, then installed over a cable or the local network. Most of this can be done from the
command line. Some steps can only be done by the user, on the Mac or the phone; ask them, then
wait.

### Steps only the user can do

Ask for these as they come up, not all at once.

1. **Sign in to Xcode** with their Apple Account: Xcode → Settings → Accounts. A free account is
   fine. There's no command-line way to do this.
2. **Connect and unlock the phone**, and tap Trust on the phone if it asks.
3. **Turn on Developer Mode:** Settings → Privacy & Security → Developer Mode, then restart. The
   switch only appears after the phone has been connected to a Mac running Xcode.
4. **After the first install, trust the developer:** Settings → General → VPN & Device Management
   → their Apple Account → Trust.
5. **Allow the microphone** when InstTuner first opens.

### Commands

1. Check the tools. Xcode must be 26 or newer.

   ```bash
   xcodebuild -version
   ```

2. Find the phone. It should be listed as `available (paired)`. If it isn't, ask the user for
   step 2 or 3 above.

   ```bash
   xcrun devicectl list devices
   ```

3. Find the user's team ID: the 10-character `organizationalUnitName`. If nothing prints, the user
   hasn't signed in to Xcode yet (step 1), or Xcode hasn't made a signing certificate; it makes
   one the first time it builds with `-allowProvisioningUpdates`.

   ```bash
   security find-certificate -a -c "Apple Development" -p | openssl x509 -noout -subject -nameopt multiline | grep organizationalUnitName
   ```

4. Choose a bundle identifier unique to the user, such as `com.<their name>.InstTuner`, and keep
   it for future renewals; reusing it keeps their settings. Build a release build. Debug builds
   run the pitch engine much slower.

   ```bash
   xcodebuild -project InstTuner.xcodeproj -scheme InstTuner -configuration Release \
     -destination generic/platform=iOS -derivedDataPath build -allowProvisioningUpdates \
     DEVELOPMENT_TEAM=<team id> PRODUCT_BUNDLE_IDENTIFIER=<bundle id> build
   ```

5. Install it, then open it.

   ```bash
   xcrun devicectl device install app --device <device id> build/Build/Products/Release-iphoneos/InstTuner.app
   xcrun devicectl device process launch --device <device id> <bundle id>
   ```

   If the launch fails because the developer isn't trusted, ask the user for step 4, then launch
   again.

Pass the team and bundle identifier on the command line, as above. Don't commit them to
`project.pbxproj`.

### Renewing

On a free account the app stops opening after 7 days. Run steps 4 and 5 again with the same
bundle identifier. Settings and custom tunings are kept.

### Errors

| Error contains | Cause and fix |
|---|---|
| `No Account for Team` or `No signing certificate` | The user isn't signed in to Xcode with that team (step 1), or the team ID is wrong. |
| `Failed to register bundle identifier` | Someone else has that bundle identifier. Pick a more specific one. |
| `maximum number of apps for free development profiles` | Free accounts can have 3 such apps on a phone. Ask the user which app to delete. |
| `Developer Mode disabled` | Step 3. |
| `developer disk image could not be mounted` or `connection to this device has not been established` | The phone is locked or out of reach. Ask the user to unlock it and connect the cable. |
| `invalid code signature` or `untrusted developer` at launch | Step 4. |

## Working on the code

- `Packages/TunerCore` is the pitch engine and music theory: no UI, tested on the Mac. `InstTuner/`
  is the SwiftUI app. The README explains how the engine works.
- Run the tests before and after a change: `cd Packages/TunerCore && swift test`.
- Pitch engine changes should come with tests. If you have the University of Iowa recordings, run
  `TUNER_RECORDINGS=<folder> swift test --filter RecordingTests` before and after, and compare
  the totals it prints.
- Debug builds take `-demo YES` and the other launch arguments in the README to replace the mic
  with a synthesised signal, so the screen can be checked in the simulator without sound.
- Swift 6 with strict concurrency. Keep the build free of warnings. Code on the real-time audio
  thread must not allocate, lock or touch actor isolation.
- No third-party dependencies, network access, analytics, ads or accounts.
- Keep on-screen text short; cut any words the player doesn't need.
