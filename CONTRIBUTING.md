# Contributing

Thanks for helping. InstTuner is a personal project worked on in spare time. Issues and pull
requests are all read, but there's no set response time.

## What InstTuner is for

A free, accurate tuner for guitar and bass that looks good and has nothing locked. It stays
free, with no ads, accounts, tracking, analytics or network access. Changes that add any of
those won't be merged.

New instruments and bigger features are worth an issue first, so we can agree on the idea before
you write code.

## Reporting a bug

Open an issue and include:

- your iPhone model and iOS version
- the instrument, the tuning selected in the app, and the string or note you played
- what the tuner showed, and what you expected (another tuner's reading helps)
- a short screen recording, if you can

Pitch problems are much easier to fix with a recording of the note. A voice memo from the same
phone, attached as a file, is perfect.

## Sending a pull request

1. Keep it to one change. Smaller pull requests get reviewed sooner.
2. Run `cd Packages/TunerCore && swift test`. Everything must pass.
3. Pitch engine changes need tests. If you have the University of Iowa recordings, include the
   `RecordingTests` totals from before and after your change.
4. Screen changes need before and after screenshots.
5. Build with no new warnings, and don't add third-party dependencies.
6. Don't commit your own signing team or bundle identifier. Pass them on the command line, as in
   [AGENTS.md](AGENTS.md).

By sending a pull request you agree that your contribution is licensed under the MIT licence, the
same as the rest of the project.
