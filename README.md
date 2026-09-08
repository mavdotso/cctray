# cctray

A macOS menu bar app for Claude Code. Shows usage limits, lists running
sessions, and jumps you back to the terminal tab that needs attention.

Requires macOS 14 or later.

<img src="menu.png" alt="The cctray menu: usage gauges, toggles, account switcher, running sessions" width="336">

## Features

- **Usage** — session, weekly and per-model limits with reset countdowns.
- **Sessions** — every running `claude` process, its project and conversation
  title, and whether it is working or idle. Click one to focus its tab.
- **Attention chime** — a sound and a notification when a session finishes,
  suppressed when you are already looking at that tab.
- **New Session** — ⌘⌥C anywhere starts `claude` in your chosen folder.
- **Keep Mac Awake** — blocks idle and lid-close sleep while sessions run.
- **Pre-warm** — sends one cheap prompt when your limit window resets.
- **Clean worktrees** — finds git worktrees with no commits for 7+ days (the
  limit is a setting) and removes them along with their Claude transcripts and
  scratchpads, on request or automatically.
- **Accounts** — save and switch between Claude logins.

## Installing

Build from source. There is no binary download yet. This checks out the app
only, not the website:

```sh
git clone --filter=blob:none --sparse https://github.com/mavdotso/cctray.git \
  && cd cctray && git sparse-checkout set apps/macos \
  && apps/macos/Scripts/build-app.sh \
  && open apps/macos/build/cctray.app
```

The build is signed with whatever Apple certificate is installed, so it runs
on the Mac that built it.

## Permissions

cctray asks for three things on first launch. All are optional; the features
that need them stop working if you decline.

| Permission | Needed for |
|---|---|
| Accessibility | The ⌘⌥C hotkey, and typing into Ghostty and Warp, which have no scripting API. |
| Automation | Opening tabs and focusing sessions in Terminal and iTerm2. |
| Notifications | The attention banner. The chime works without it. |

The attention chime installs a `Stop` hook into `~/.claude/settings.json` that
appends one line per finished session to
`~/Library/Application Support/cctray/attention.jsonl`. Turning the chime off
removes the hook.

## Privacy

cctray talks to two network endpoints, both Anthropic's:

- `api.anthropic.com/api/oauth/usage` reads your own usage numbers.
- `console.anthropic.com/v1/oauth/token` renews an expired login, so the
  switcher can show usage for an account you are not currently using. cctray
  only calls it when a saved token has expired.

It reuses the OAuth token Claude Code already stores —
`~/.claude/.credentials.json` where Claude Code keeps one, otherwise the
`Claude Code-credentials` login keychain item. A saved account profile keeps
its own copy in a `cctray-profile-` keychain item, and a renewed token is
written back to it. All keychain reads and writes go through
`/usr/bin/security`, so the app's location never matters to the keychain.
Nothing else leaves your Mac.

## Repository layout

```
apps/macos    the menu bar app (Swift, SwiftPM)
apps/web      the marketing site (Astro)
```

## Development

```sh
swift build --package-path apps/macos
```

The app icon is generated, not hand-drawn. Re-run it after changing the design:

```sh
cd apps/macos && swift Scripts/make-icon.swift   # -> apps/macos/AppIcon.icns
```

## License

MIT — see [LICENSE](LICENSE). The chime synthesiser is ported from
[cuelume](https://github.com/Danilaa1/cuelume); see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
