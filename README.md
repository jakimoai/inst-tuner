# InstTuner

A free iPhone tuner for guitar and bass, with nothing locked. No accounts, ads, in-app purchases
or network access.

![InstTuner tuning the A string flat, high E in tune, and a 12-string custom tuning](docs/screenshots.png)

## What it does

- Guitar (6, 7 and 8 strings) and bass (4, 5 and 6 strings), reading down to A0 for low B and drop tunings.
- 46 preset tunings, plus your own with per-string cents offsets, or chromatic mode for any note.
- Equal temperament and 9 historical tuning systems in any key, a custom system, and A4 from 390 to 490 Hz.
- Needle, strobe, pitch trace and spectrum views.
- Reference tones, weighted so low strings can be heard on a phone speaker.
- A big note name you can read from a music stand, and a glow behind it that drifts left when flat and right when sharp.

## Install it on your iPhone

InstTuner isn't on the App Store. An iPhone only runs apps signed for it, so there's no download:
you build it on a Mac and install it on your own phone. It's free, and takes about 15 minutes the
first time.

Using a coding agent? Point it at [AGENTS.md](AGENTS.md). It has the exact commands, and says
which steps only you can do on the phone.

**You need:** a Mac with Xcode 26 (free from the Mac App Store), an iPhone on iOS 26, a cable, and
an Apple Account. A free account is enough.

1. **Get the code.** Run `git clone https://github.com/jakimoai/inst-tuner.git`, or download the
   ZIP from the green Code button.
2. **Sign in to Xcode.** Open Xcode, go to Settings → Accounts, and add your Apple Account.
3. **Open the project.** Open `InstTuner.xcodeproj`. Select the InstTuner target, then the Signing
   & Capabilities tab. Set Team to your account (it says "Personal Team" on a free account), and
   change Bundle Identifier to something only you will use, like `com.yourname.InstTuner`.
4. **Use a release build.** Go to Product → Scheme → Edit Scheme → Run, and set Build
   Configuration to Release. Debug builds work, but the pitch engine runs much slower in them.
5. **Connect the phone.** Plug it in, unlock it, and tap Trust if it asks.
6. **Turn on Developer Mode.** On the phone, go to Settings → Privacy & Security → Developer Mode,
   turn it on, and restart when asked. The switch only appears after the phone has been connected
   to Xcode once.
7. **Install.** In Xcode, choose your phone from the device menu at the top, then press Run (⌘R).
8. **Trust yourself as a developer.** The first launch fails with "Untrusted Developer". On the
   phone, go to Settings → General → VPN & Device Management, tap your Apple Account, and tap
   Trust.
9. **Open InstTuner** and allow the microphone.

**Free account limits:** the app stops opening after 7 days. Connect the phone and press Run
again to renew it; your settings and tunings are kept. A free account can also have only 3 apps
like this on a phone at once. The paid Apple Developer Program (US$99 a year) extends signing to a
year.

**If something goes wrong:**

| Message | Fix |
|---|---|
| "Signing for InstTuner requires a development team" | Step 3: pick your team. |
| "Failed to register bundle identifier" | Step 3: the bundle identifier is taken; make it more unique. |
| "Developer Mode disabled" | Step 6. |
| "Untrusted Developer" on the phone | Step 8. |
| "The maximum number of apps for free development profiles has been reached" | Delete another app you installed this way, or use the paid program. |
| Readings missing, or the screen says the microphone is off | Settings → InstTuner → turn on Microphone. |

## How the pitch engine works

1. **Period** (`PeriodDetector`): finds the waveform's repeating period, which still works when a
   phone mic can't hear a low string's fundamental.
2. **Octave** (`PitchEngine`): decided just after the pluck, then held until the next one, using
   the strings being tuned when there are any. Sound whose level never fades, like mains hum,
   is treated as background.
3. **Pitch** (`PartialAnalyzer`): measures each overtone precisely and combines them, weighted by
   loudness, into the pitch the ear hears. A stiff bass string's overtones run sharp, so this
   sits a few cents above its theoretical fundamental, which is what players tune to and what
   other tuners show. A string-stiffness model predicts where each overtone will be.
4. **Reading** (`PitchTracker`): ignores glitches, follows real changes, holds the last reading.

The engine lives in `Packages/TunerCore`, which has no UI and is tested without a phone. The app
in `InstTuner/` is SwiftUI.

## Test

```bash
cd Packages/TunerCore && swift test
```

To score real recordings, download the guitar and pizzicato double bass files from the
[University of Iowa samples](https://theremin.music.uiowa.edu/MIS.html) into a folder, then:

```bash
TUNER_RECORDINGS=/path/to/folder swift test --filter RecordingTests
```

Debug builds accept launch arguments that replace the mic with a synthesised signal, for working
on the screen without an instrument:
`-demo YES -demoString 0 -demoCents m12 -demoTuning b5.standard -demoReadout strobe`.

## Issues and pull requests

Both are welcome and both get read. InstTuner is a personal project worked on in spare time, so
there's no set response time.

- **Found a bug?** Open an issue with your iPhone model, iOS version, instrument and tuning, and
  what the tuner showed compared with what you expected. A short screen recording helps a lot.
- **Want a feature?** Open an issue first, so we can agree on it before you spend time on code.
- **Sending a pull request?** Keep it to one change, and make sure `swift test` passes.
  [CONTRIBUTING.md](CONTRIBUTING.md) has the details.

InstTuner stays free, with no ads, accounts, tracking or network access. Changes that add those
won't be merged.

## Licence

MIT. See [LICENSE](LICENSE).
