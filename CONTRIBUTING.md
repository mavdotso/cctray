# Contributing

## What you need

| Tool | Version | Used for |
|---|---|---|
| macOS | 14 or later | running the app |
| Xcode | 16 or later (Swift 6) | building the app |

The app has no third-party dependencies.

## Build and run the app

```sh
git clone https://github.com/mavdotso/cctray.git && cd cctray \
  && apps/macos/Scripts/build-app.sh \
  && ditto apps/macos/build/cctray.app /Applications/cctray.app \
  && open /Applications/cctray.app
```

To skip the website, add `--filter=blob:none --sparse` to the clone and then
`git sparse-checkout set apps/macos`. The README tells users to do this.

`swift run` does not work: the app needs a real bundle for notifications. Always
use the build script. It signs with a Developer ID certificate when one is in
your keychain, otherwise with an Apple Development certificate, otherwise ad hoc.
Ad-hoc builds run on your Mac only.

Quit the previous copy before replacing or launching the app:

```sh
pkill -x cctray
```

The first launch asks for Accessibility, Automation and Notifications. All are
optional. See the README for what each one unlocks.

## Repository layout

```
apps/macos/Sources/cctray   the app, grouped by feature
apps/macos/Scripts          build-app.sh and the icon generator
apps/web                    the website, deployed by Vercel
.github/workflows/ci.yml    builds both apps
```

Files are grouped by feature. `Accounts.swift` and `CodexAccounts.swift` own
Profile selection. `ClaudeLogin.swift` owns renewal and credential preservation;
`ClaudeUsageClient` in `UsageClient.swift` owns authenticated usage reads and
retry deadlines. `CodexLoginManager` in `Codex.swift` owns refresh and logout
sequencing through the installed CLI. `LoginMaintenance.swift` schedules checks
at launch, periodically, and after wake. `SessionDiscovery.swift` resolves terminal sessions
and transcripts; `Sessions.swift` manages polling. `PreWarm.swift` schedules both
agents. Views are in `MenuView.swift`, `SettingsView.swift` and
`CleanWorktreesView.swift`.

## Conventions

- Keep it small. Prefer deleting code to adding it. Use the standard library
  and the platform before writing something new.
- No comments unless the code cannot be understood without one. When one is
  needed, use a single `/* */` block.
- Nothing user-specific in the source: no home paths, no account names, no
  signing identities. Read them at runtime.
- All user-facing text follows the existing tone: short, plain, no jargon.
- Keychain access goes through `/usr/bin/security`. Direct `SecItem` calls tie
  an item to the app's path and cause prompts after every move or rebuild.
- Start processes through `Shell` in `Support.swift`; use `Shell.start` for
  interactive pipes, `Shell.run` for captured output and `Shell.fire` to launch.

## Sending a change

1. Branch from `main`.
2. Build the app with `build-app.sh` and run it. Say in the pull request what you
   tried and what you saw.
3. Open a pull request. CI must be green: it builds the app in release mode on
   macOS.
4. One change per pull request. Keep the description to what changed and why.

`main` is protected: no force pushes, no deletions, and CI has to pass before a
merge.

Credential lifecycle tests use synthetic logins and in-memory storage. Run them
with `swift test --package-path apps/macos`; they do not read or refresh your
real logins. CI runs these tests alongside the release build.

`LiveLoginTests` are skipped by default. With explicit authorization to contact
the providers and save rotated credentials, quit cctray and run
`CCTRAY_LIVE_LOGIN_TESTS=1 swift test --package-path apps/macos --filter LiveLoginTests`.
These tests use existing Claude Keychain logins and Codex profiles. They never
print tokens. For a provider rate limit, wait until its retry deadline before
rerunning the usage test.

## Releasing

Update `CFBundleShortVersionString` in `apps/macos/Info.plist` for a new version.
The build script uses that version by default; `VERSION` can override it for a
local build. Tag the merged release commit with the matching `v` version.

There is no binary distribution yet. Users build from source.
