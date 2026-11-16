# Claude Multi Account — architecture

FOSS (MIT), clean-room. Deployment target **macOS 26 only**.
UI follows **Apple Liquid Glass** (macOS 26 native apps), not the original's cream theme.

## Names
- App: "Claude Multi Account", bundle id `com.apolloautomation.claudemultiaccount`
- Profile apps: `~/Applications/Claude Multi Account/Claude (<Name>).app`, id `com.apolloautomation.claudemultiaccount.profile.<id8>`
- Data: `~/Library/Application Support/Claude Multi Account/` → `profiles.json`, `state.json`, `Profiles/<UUID>/` (Electron user-data-dir), `CLI/<UUID>/` (per-profile CLAUDE_CONFIG_DIR), `Build/`, `Backups/`, `Locks/`, `Journal/`
- Info.plist keys for profile apps: `CMAProfileID`, `CMAProfileName`, `CMAUserDataDir`, `CMAColor`, `CMAShowBorder`, `CMABorderWidth`, `CMAClaudeConfigDir` (optional), `CMAAgentHash`, `CMABuilderVersion`

## Facts confirmed on a real Mac
- Regular Claude main process has no `--user-data-dir`; profile main process has `--user-data-dir=<dir>` as one argv element (path with spaces). Helpers also carry it — only consider main processes (`NSWorkspace.runningApplications`, bundle id `com.anthropic.claudefordesktop`).
- Sessions: `claude-code-sessions/<accountUuid>/<orgUuid>/local_<uuid>.json` (filename = sessionId). Keys: `cliSessionId`, `createdAt`, `lastActivityAt` (ms), `completedTurns`, `lastTurnEdgeAt`, `isArchived`, `cwd`. Siblings: `scheduled-tasks.json`, `archived-sessions.idx` (`{"v":1,"archived":[ids]}`), `deleted_<uuid>` tombstones, `backlog/`, `waiting-input/` — never synced.
- Transcripts: `~/.claude/projects/<encoded-cwd>/<cliSessionId>.jsonl` (shared, not per data dir).
- Account: `config.json.lastKnownAccountUuid`. `config.json` also holds `oauth:tokenCache*` — NEVER read into a write path, never log.
- Plan usage `plan-usage-history.json`: `{"version":2,"samples":[{"t":ms,"org":uuid,"u":{"fh":%,"sd":%}}]}` — `fh`/`sd` both optional.
- `claude_desktop_config.json`: `mcpServers` (may be absent), `preferences`. `extensions-installations.json` `{extensions:{<id>:…}}` + `Claude Extensions/<id>/` + `Claude Extensions Settings/<id>.json`.
- Memory notes: YAML frontmatter (`name`, `description`, `type`) + body; `MEMORY.md` lines `- [Title](file.md) — desc`. Project dir name encodes `/` and `.` as `-` (lossy) — get display path from `cwd` in a transcript's first line.
- Dock tile: `tile-data{file-data{_CFURLString,_CFURLStringType=15}, file-label, bundle-identifier, file-type=41}`.
- Claude.app updates via Squirrel/ShipIt (`~/Library/Caches/com.anthropic.claudefordesktop.ShipIt`).
- A third-party profile app (Fynora) may be installed — its instances are **foreign**: read-only, never touched.

## Package layout (SwiftPM only, no deps, swift-tools 6.2, `.macOS(.v26)`)
| Target | Kind | Depends | Rule |
|---|---|---|---|
| `CMACore` | library | Foundation, CryptoKit | Pure logic; all paths via injected `AppPaths` |
| `CMASystem` | library | CMACore, AppKit, CoreAudio, Carbon | Side effects behind protocols |
| `ProfileAgent` | executable | CMACore, CMASystem | Copied into every profile app |
| `ClaudeMultiAccount` | executable | CMACore, CMASystem, SwiftUI | Manager app |
| `CMACoreTests`, `CMASystemTests` | swift-testing | | temp dirs only, never real user data |

### CMACore files
AppPaths, Profile (Profile/ProfileColor/BorderWidth/HotKeySpec), ProfileStore (actor, atomic profiles.json), RuntimeStateStore (state.json), NameValidator, Slug, ProfileInfoPlist, AtomicFile, SafePath, ClaudeDataDir, PlanUsage, CacheInventory, SessionRecord + SessionSyncPlanner, SettingsImportPlanner, TerminalScript, MemoryStore + MemoryOps, BackupManifest, DockPlist, LinkRouting, ProcArgs, OperationJournal, IPC, Contracts (protocols).

### CMASystem files
ProcessScanner, ClaudeLocator, ClaudeLauncher, DataDirLock (flock), IconRenderer (CoreGraphics → icns), BundleBuilder (stage, `codesign --force --sign - --timestamp=none`, swap, `lsregister -f`), Subprocess (argv only, never a shell), DockEditor, DesktopShortcut (Finder alias bookmark), TerminalCommandInstaller, HotKeyCenter (Carbon RegisterEventHotKey), LinkHandlerRegistration (`NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`), URLForwarder (GURL Apple Event to pid), BackupArchiver (/usr/bin/zip, unzip), SessionSyncExecutor, SettingsImportExecutor, RegularClaudeMover, MicUsageMonitor, SpotifyController, LoginItem (SMAppService.mainApp).

### ProfileAgent files
main.swift, AgentDelegate (read own Info.plist, launch or activate, reopen), ClaudeSession (pid observation), UpdateWatcher (ShipIt relaunch), BorderOverlayController + WindowTracker.

### ClaudeMultiAccount files
App.swift, AppModel (@Observable, 2 s rescan + workspace notifications), StatusItemController (NSStatusItem + NSMenu: ⌥-click quit, optional front-profile letter), Views/ (Sidebar, ProfileDetail, RegularClaude, Memory, NewProfileSheet, EditProfileSheet, Onboarding, Settings, LinkPicker, SyncSheet, ImportSheet, UsageBars, ShortcutRecorder), Coordinators/ProfileActions.

### scripts/build-app.sh
`swift build -c release` (UNIVERSAL=1 → `--arch arm64 --arch x86_64`), assemble `build/Claude Multi Account.app/Contents/{Info.plist, MacOS/ClaudeMultiAccount, Resources/ProfileAgent, Resources/AppIcon.icns}`. Info.plist: `LSUIElement`, `CFBundleURLTypes` for `claude` (rank Alternate), `NSAppleEventsUsageDescription`, `NSDesktopFolderUsageDescription`, `LSMinimumSystemVersion 26.0`. App icon via `ClaudeMultiAccount --render-app-icon <path>`. Sign agent then app with `codesign --force --sign "${CODESIGN_IDENTITY:--}"` (no --deep), then `codesign --verify --strict`.

## Mechanisms (summary — implement exactly)
- **Launch:** everything (manager, hotkey, Dock, alias) opens the *profile app*; agent is single-instance via LaunchServices; reopen → activate Claude pid. Agent finds instance by data dir via `KERN_PROCARGS2` (ProcArgs; accept `--user-data-dir=X` and `--user-data-dir X`; standardized, symlink-resolved, case-insensitive compare). Launch: `NSWorkspace.openApplication`, `createsNewApplicationInstance=true`, args `["--user-data-dir=<dir>"]`, `addsToRecentItems=false`, env `CLAUDE_CONFIG_DIR` only if set. Agent takes DataDirLock; busy → "Profile is busy" alert. Activate via `NSRunningApplication.activate`; fallback System Events by unix id.
- **Self-update:** on Claude exit, if ShipIt alive or cache dir changed <60 s: wait ShipIt exit + Info.plist readable (0.5 s poll, 120 s), watch 20 s for a new flagless Claude main process; if seen and regular Claude wasn't running before, terminate it; relaunch on profile. Else exit.
- **Border:** CGWindowListCopyWindowInfo (on-screen, exclude desktop) filtered to pid, layer 0, alpha>0, ≥120×80; flip Y; one borderless clear click-through NSWindow per target with CAShapeLayer stroke; `order(.above, relativeTo:)` normal level; `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`; full screen → radius 0; 30 Hz when frontmost/moving else 4 Hz; hide during drag, reshow after 150 ms stable. Re-read border settings on `profileChanged.<id>` distributed notification.
- **Icon:** CoreGraphics/CoreText squircle (824/1024 grid), gradient of profile color, white heavy first letter; write icns via CGImageDestination `com.apple.icns`.
- **Bundle build:** stage in `Build/<uuid>/`, sign, verify, `replaceItemAt`, lsregister. Stale = agent hash or builder version differs → rebuild non-running profiles at launch.
- **Dock:** CFPreferences `com.apple.dock` `persistent-apps`, DockPlist transform, sync, `killall Dock` (only on explicit user action).
- **Link routing:** claim scheme `claude`; kAEGetURL handler validates; 0 running → regular Claude, 1 → forward, many → picker (preselect most recently active); forward via GURL Apple Event to pid; not-running profile → open its app with `--open-url`.
- **Move regular Claude:** require quit (offer terminate, wait 10 s), journal, single `rename(2)` to `Profiles/<UUID>`, add profile, build app; cross-volume → copy+verify+Trash; journal recovery at launch.
- **Backup:** require quit; zip `<UUID>/…` + `manifest.json` (formatVersion 1); exclude cache dirs, Crashpad, sentry, vm_bundles, claude-code-vm, claude-code, claude-code-spare, Singleton*. Restore: `unzip -Z1` validate (no absolute, no `..`, single root), extract to Build/restore-*, check formatVersion, new UUID + deduped name.
- **Session sync:** unit = record file. Further along: completedTurns, then lastActivityAt, then lastTurnEdgeAt, then mtime; identical hash skip. Same account → two-way within `<account>/*`; different → one-way, user picks direction, rehome into dest `<account>/<org>`. Skip if dest has `deleted_<id>`. Update `archived-sessions.idx` for copied ids only. Back up replaced files to `Backups/session-sync/<ts>/`. Never delete.
- **Import (regular → profile):** missing-only merge of mcpServers/preferences/top-level keys of claude_desktop_config.json; developer_settings.json; missing extensions. `config.json` is never read, rewritten or backed up by import (no theme import).
- **Terminal command:** `claude-<slug>` in `~/.local/bin` (or `/usr/local/bin`); marker comment with profile id; `export CLAUDE_CONFIG_DIR='<App Support>/CLI/<UUID>'`; loop over candidates (`~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.claude/local/claude`, `~/.npm-global/bin/claude`) and `exec` first with `"$@"`, else exit 127. CLI dir seeded with symlinks to `~/.claude/{CLAUDE.md,settings.json,skills,projects,agents,plugins}`. Never overwrite a file lacking our marker.
- **Memory:** list `~/.claude/projects/*/memory/*.md` minus MEMORY.md; Copy to Project with replace/keep-both/skip + backup + MEMORY.md index line; Make General Rules appends `## <name>` + body under `# Rules shared from project memory` in `~/.claude/CLAUDE.md` with `<!-- cma:<project>/<file> -->` dedupe marker, backup first.
- **Music pause:** per-process CoreAudio objects (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyBundleID` prefix `com.anthropic.claudefordesktop`, `kAudioProcessPropertyIsRunningInput`); Spotify via AppleScript only if running & playing; resume 1.5 s after mic stops if we paused.
- **Usage:** latest sample by `t` for the profile's org; "—" if missing or 5-hour value older than 5 h; warn ≥80, critical ≥95.
- **Delete profile:** require quit; remove hotkey, Dock entry, alias, script, app; move data dir to **Trash**.
- **Hotkeys:** own Carbon wrapper; ≥1 modifier; already-in-use error surfaced.

## Known hard edge cases (from the original developer — must handle)
1. **Claude reclaims `claude://` on every launch.** Claude Desktop re-registers itself as default handler each start (original binary logs "took claude:// back from …" and has a `reclaimTask`/`watchdog`). When link routing is on, the manager must: observe `NSWorkspace.didLaunchApplicationNotification` for `com.anthropic.claudefordesktop` (and wake / every 60 s as a safety net), check `NSWorkspace.urlForApplication(toOpen: claude://)`, and re-claim with `setDefaultApplication` after a ~3 s debounce if it isn't us. Never fight in a tight loop (back off; log). Turning routing off hands it back to Claude.app once and stops watching.
2. **Session sync must never lose chats.** Copy only whole record files; compare by completedTurns → lastActivityAt → lastTurnEdgeAt → mtime; never replace a record that is further along; back up every replaced file first; never delete; skip tombstoned ids; both sides quit + locked; verify each written file parses as JSON before committing (temp + rename); dry-run preview shown to the user before execution. The transcripts in `~/.claude/projects` are shared, so they are never touched.
3. **Moving a sign-in without logging in again.** Sign-in (cookies, `oauth:tokenCache*`) is encrypted with Electron safeStorage using the login-keychain item "Claude Safe Storage", which all instances of the same Claude.app share. So: move the *whole* data dir byte-for-byte with `rename(2)` (never selectively copy or rewrite `config.json`, `Cookies`, `Local State`), keep the same Claude.app (never re-sign or copy Claude), and never launch a profile with a different keychain context. Cross-volume fallback copies preserving everything (`FileManager.copyItem`, then verify file count + sizes) before trashing the source. Backups restored on *another* Mac need a new sign-in (different keychain key) — UI must say so.

## Safety rules
- All data-dir mutations go through `withQuitDataDir(dir)` — lock, assert not running, re-check before commit.
- Regular Claude dir: only whole-dir rename (move) and atomic replace under `claude-code-sessions/` (sync). Never delete there.
- `SafePath.require` before remove/replace/trash. Atomic writes (temp + fsync + rename). JSON via JSONSerialization to preserve unknown keys. Backups before every replace. Journal for multi-step ops.
- Never log/decode `oauth:*`. Subprocess argv only. AppleScript sources are constants.

## UI (Liquid Glass, macOS 26)
- `NavigationSplitView` with system sidebar (glass), `.searchable` (⌘F) for profiles. Sidebar sections: Profiles (badge + name + status), On This Mac (Regular Claude), Claude Code (Memory).
- Toolbar: New Profile (`.buttonStyle(.glassProminent)`), More menu. Detail pages: `Form`/`.formStyle(.grouped)` sections — header (big badge, title, status capsule, Edit/Quit/Open or Bring to Front), Plan Usage (two `Gauge`/ProgressView cards in `GlassEffectContainer`), Switching (shortcut recorder, Dock, Desktop), Telling It Apart (color swatches, border toggle, thickness segmented), Bring Over From Regular Claude, Terminal Command, Backup & Storage, Profile App.
- Glass belongs to the control layer only (toolbar, sidebar, sheet action buttons, floating controls). Content = standard grouped `Form` sections; no custom card backgrounds, no glass on glass, no monospaced uppercase headers.
- Toolbar: primary Open / Bring to Front `.glassProminent`; Edit, Quit; New Profile (`plus`); `Menu` (`ellipsis`) with Rebuild, Show in Finder, Delete; `.navigationTitle` = name, `.navigationSubtitle` = status.
- Profile colors map to system colors (`Color.orange`…, `NSColor.system*` in the agent). `Theme.swift` = badge view + color mapping only.
- Memory: grouped Form for general rules; notes in a multi-select `List` grouped per project; Copy to Project / Make General Rules as toolbar items; conflicts via `.confirmationDialog`.
- Sheets for New Profile (radio group: start empty / move regular Claude / restore backup), Edit, Sync, Import (preview list + confirm). Onboarding: sheet, paged steps, `.interactiveDismissDisabled()`.
- Menu bar: `MenuBarExtra` with `.menuBarExtraStyle(.menu)` (no NSStatusItem); label SF Symbol or front profile letter; open profiles first, each a submenu Bring to Front / Quit; ⌥-click quit via `NSEvent.modifierFlags`.
- Link picker: own `Window` scene, `.windowResizability(.contentSize)`, `.windowLevel(.floating)`, URL in selectable monospaced text, default button `.glassProminent` + `.keyboardShortcut(.defaultAction)`.
- `Settings` scene with TabView: General (launch at login, menu bar letter, link routing, music pause) and About (version, MIT notice). No license/trial/update/analytics UI. No network calls.
- Activation policy `.regular` while main window/Settings open, `.accessory` otherwise (`LSUIElement` true).
- Own UI copy (clean-room); do not reuse the original's wording verbatim.
