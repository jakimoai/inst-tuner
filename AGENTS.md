# Instructions for coding agents

This file tells AI coding agents how to work in this repo, most often to install InstTuner on
someone's iPhone. People can follow it too. The README has the same install steps for Xcode's
interface.

## Install InstTuner on the user's iPhone

InstTuner isn't on the App Store. You build it, sign it with the user's own Apple Account, and
install it over a cable or the local network. You can run most of this from the command line. The
user has to do some steps on the Mac or the phone, so ask them and wait.

### Steps only the user can do

Ask for each one when you reach it, not all at once.

1. **Sign in to Xcode.** In Xcode, open Settings, choose Accounts, and add their Apple Account. A
   free account works. No command does this.
2. **Connect and unlock the phone.** Tap Trust on the phone if it asks.
3. **Turn on Developer Mode.** On the phone, open Settings, then Privacy & Security, then
   Developer Mode, and restart. The switch appears only after the phone has connected to a Mac
   running Xcode once.
4. **Trust the developer after the first install.** On the phone, open Settings, then General,
   then VPN & Device Management, tap their Apple Account, and tap Trust.
5. **Allow the microphone** when InstTuner first opens.

### Commands

1. Check that Xcode is version 26 or newer.

   ```bash
   xcodebuild -version
   ```

2. Find the phone. It should show as `available (paired)`. If it doesn't, ask the user for step 2
   or 3 above.

   ```bash
   xcrun devicectl list devices
   ```

3. Find the user's team ID. It's the 10-character `organizationalUnitName` this command prints.
   If it prints nothing, the user hasn't signed in to Xcode (step 1), or Xcode hasn't made a
   signing certificate yet. Xcode makes one the first time it builds with
   `-allowProvisioningUpdates`.

   ```bash
   security find-certificate -a -c "Apple Development" -p | openssl x509 -noout -subject -nameopt multiline | grep organizationalUnitName
   ```

4. Pick a bundle identifier that only this user will use, such as `com.<their name>.InstTuner`.
   Use the same one every time, because a new one installs a second copy and loses their
   settings. Build a release build, because the pitch engine runs much slower in a debug build.

   ```bash
   xcodebuild -project InstTuner.xcodeproj -scheme InstTuner -configuration Release \
     -destination generic/platform=iOS -derivedDataPath build -allowProvisioningUpdates \
     DEVELOPMENT_TEAM=<team id> PRODUCT_BUNDLE_IDENTIFIER=<bundle id> build
   ```

5. Install the app, then open it.

   ```bash
   xcrun devicectl device install app --device <device id> build/Build/Products/Release-iphoneos/InstTuner.app
   xcrun devicectl device process launch --device <device id> <bundle id>
   ```

   If the launch fails because the phone doesn't trust the developer, ask the user for step 4,
   then launch again.

Pass the team ID and bundle identifier on the command line, as above. Don't commit them to
`project.pbxproj`.

### Renewing

A free account signs the app for 7 days, and then it stops opening. Run steps 4 and 5 again with
the same bundle identifier. The app keeps its settings and custom tunings.

### Errors

| Error contains | Cause and fix |
|---|---|
| `No Account for Team` or `No signing certificate` | The user hasn't signed in to Xcode with that team (step 1), or the team ID is wrong. |
| `Failed to register bundle identifier` | Someone else has that bundle identifier. Pick a more specific one. |
| `maximum number of apps for free development profiles` | A free account can keep 3 apps like this on a phone. Ask the user which one to delete. |
| `Developer Mode disabled` | Ask the user for step 3. |
| `developer disk image could not be mounted` or `connection to this device has not been established` | The phone is locked or out of reach. Ask the user to unlock it and plug in the cable. |
| `invalid code signature` or `untrusted developer` at launch | Ask the user for step 4. |

## Working on the code

- `Packages/TunerCore` holds the pitch engine and the music theory. It has no UI, and its tests
  run on a Mac. `InstTuner/` holds the SwiftUI app. The README explains how the engine works.
- Run the tests before and after a change: `cd Packages/TunerCore && swift test`.
- Add tests with any pitch engine change. If you have the University of Iowa recordings, run
  `TUNER_RECORDINGS=<folder> swift test --filter RecordingTests` before and after, and compare
  the totals it prints.
- To check the screen in the simulator without sound, launch a debug build with `-demo YES` and
  the other arguments in the README. They replace the mic with a synthesised signal.
- The code uses Swift 6 with strict concurrency. Keep the build free of warnings. Code on the
  real-time audio thread must not allocate memory, take a lock or touch actor isolation.
- Don't add third-party dependencies, network access, analytics, ads or accounts.
- Keep on-screen text short, and cut any word the player doesn't need.
