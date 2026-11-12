# Contributing

Thanks for helping. I work on InstTuner in my spare time. I read issues and pull requests, but
I can't promise how soon I'll reply.

## What InstTuner is for

InstTuner is a free, accurate tuner for guitar and bass with no paid features. It will stay free,
with no ads, accounts, tracking, analytics or network access. I won't merge changes that add any
of those.

Before you write code for a new instrument or a bigger feature, open an issue so we can agree on
the idea.

## Reporting a bug

Open an issue and include these:

- your iPhone model and iOS version
- the instrument, the tuning you picked in the app, and the string or note you played
- what the tuner showed, and what you expected, ideally with another tuner's reading
- a short screen recording, if you can make one

A recording of the note makes pitch problems much easier to fix. A voice memo from the same phone,
attached as a file, works well.

## Sending a pull request

1. Make one change per pull request. I review small pull requests sooner.
2. Run `cd Packages/TunerCore && swift test`, and check that every test passes.
3. Add tests with any pitch engine change. If you have the University of Iowa recordings, include
   the `RecordingTests` totals from before and after your change.
4. Include before and after screenshots for any change to the screen.
5. Don't add build warnings or third-party dependencies.
6. Don't commit your own signing team or bundle identifier. Pass them on the command line, as
   [AGENTS.md](AGENTS.md) shows.

By sending a pull request, you agree to license your contribution under the MIT licence, like the
rest of the project.
