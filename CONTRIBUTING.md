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
  && open apps/macos/build/cctray.app
```

To skip the website, add `--filter=blob:none --sparse` to the clone and then
`git sparse-checkout set apps/macos`. The README tells users to do this.

`swift run` does not work: the app needs a real bundle for notifications. Always
use the build script. It signs with a Developer ID certificate when one is in
your keychain, otherwise with an Apple Development certificate, otherwise ad hoc.
Ad-hoc builds run on your Mac only.

Quit the previous copy before launching a new one, or two tray icons appear:

```sh
pkill -f 'build/cctray.app'
```

The first launch asks for Accessibility, Automation and Notifications. All are
optional. See the README for what each one unlocks.

## Repository layout

```
apps/macos/Sources/cctray   the app, one file per feature
apps/macos/Scripts          build-app.sh and the icon generator
apps/macos/Tests            the checks CI runs
apps/web                    the website, deployed by Vercel
.github/workflows/ci.yml    builds both apps and runs the checks
```

Every feature lives in one file: `Accounts.swift`, `Attention.swift`,
`PreWarm.swift`, `Sessions.swift`, `Worktrees.swift`, and so on. Views are in
`MenuView.swift`, `SettingsView.swift` and `CleanWorktreesView.swift`.

## Conventions

- Keep it small. Prefer deleting code to adding it. Use the standard library
  and the platform before writing something new.
- No comments unless the code cannot be understood without one. When one is
  needed, use a single `/* */` block.
- Nothing user-specific in the source: no home paths, no account names, no
  signing identities. Read them at runtime.
- All user-facing text follows the existing tone: short, plain, no jargon.
- Keychain access goes through `/usr/bin/security`. Direct `SecItem` calls tie
  an item to the app's path and cause prompts after every move or rebuild; the
  only one left reads items written by older builds once and rewrites them.
- `Shell.run` and `Shell.fire` in `Support.swift` are the only ways to start a process.

## Sending a change

1. Branch from `main`.
2. Build the app with `build-app.sh` and run it. Say in the pull request what you
   tried and what you saw.
3. Open a pull request. CI must be green: it builds the app in release mode on
   macOS and runs `swift test`.
4. One change per pull request. Keep the description to what changed and why.

`main` is protected: no force pushes, no deletions, and CI has to pass before a
merge.

## Releasing

There is no binary distribution yet. Users build from source.
