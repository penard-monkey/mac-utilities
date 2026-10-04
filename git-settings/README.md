# Git & SSH

A native macOS 14+ app for **machine-level** Git defaults and SSH identities.
It also checks the effective identity in a chosen repository or folder.

## Install and remove

Requires Xcode or the Command Line Tools with Swift 5.9+. From this folder:

```sh
./scripts/install.sh                    # ~/Applications/Git & SSH.app
./scripts/install.sh /path/Applications # optional destination, including spaces
./scripts/uninstall.sh                  # removes the app only
./scripts/uninstall.sh /path/Applications
```

The installer builds release, renders the app icon, packages the executable,
and signs ad hoc. It does not launch the app or alter Git/SSH configuration.
It refuses to replace another bundle or a symlink. The manager integration
uses `mac-utility.json` and an isolated staging Applications directory.
Uninstall preserves Git settings, SSH keys/config, and backups.

## What the app does

- **Overview:** selected Git binary/version; global commit name/email and
  signing settings; global credential-helper presence and source; actual
  current SSH agent availability/key count. Custom helper commands and
  credential data are not displayed or executed.
- **Git Settings:** edit commit name/email, editor, initial branch, signing
  flag/format/key, and global ignore path. Add/replace/remove aliases. Empty
  values remove direct entries. Preview a line diff before applying, inspect
  global values and origins, and restore a guarded backup. The ignore file’s
  contents are not rewritten. Editors and aliases are command settings Git
  will execute later; the app does not execute them.
- **Includes and profiles:** list every direct `include.path` and
  `includeIf.<condition>.path` in the main Git config in file order, including
  duplicates. Show each target, existence and supported values stored directly
  in it. Add, change or remove unconditional, `gitdir:`, `gitdir/i:`, `onbranch:`
  and `hasconfig:remote.*.url:` rules through a preview. Relative profile paths
  resolve beside the main config; `~/` resolves under the current home.
  Existing unknown conditions remain visible and can be removed or replaced.
  Edits preserve other settings, comments and rule order. Removing a rule
  never deletes its target. Nested includes remain intact but are not editable
  unless also referenced directly from the main config.
- **Profile editor:** choose Edit profile to edit identity, signing, editor,
  initial branch, ignore path and aliases in that file. Only direct references
  inside the home folder are editable; traversal outside home, symlinks
  (including parent directories) and nonregular files are refused. To create a
  profile, add/apply a rule pointing to a missing file, choose Create profile,
  then enter and apply its settings. Use a second rule with the same target to
  share an identity across directories. Choose Edit global defaults to return
  to the main file. Each operation has its own preview and backup.
- **Effective identity:** choose a folder (or enter an absolute or `~/` path, including
  hidden folders) to read Git’s resolved commit name,
  email and signing settings with their scope and origin. Git evaluates the
  conditional rules and repository overrides. No config or repository writes
  are performed, and no credentials or helper commands are executed.
- **SSH Keys:** inventory valid `.pub` files directly under `~/.ssh`, calculate
  SHA256 fingerprints with `ssh-keygen`, copy public keys, and load/unload
  individual identities in the existing agent. Invalid, unreadable, and
  symlink public files are skipped. Keys outside this directory and
  agent-only identities are not inventoried; no public key is inferred by
  reading a private file. The key count still includes agent-only identities.
- **Generate Ed25519:** create a new key with 64 KDF rounds and native secure
  passphrase/confirmation prompts using OpenSSH askpass. Passphrases go only
  to OpenSSH’s askpass pipe, never into argument arrays, logs, settings, or
  the parent app. Empty passphrases explicitly produce an unencrypted key.
  Generation uses a private staging directory and exclusive publication;
  existing keys are never overwritten. Public-key upload and agent loading
  are separate user actions. Cancellation aborts generation.
- **SSH Hosts:** display the main config and its Host declarations; mark
  Include/Match presence. Add a validated literal alias via preview. The
  block is inserted after the global preamble and before existing scopes,
  retaining existing directives, includes, wildcard blocks and Match rules.
  Earlier global/include values may win. Included hosts are not expanded,
  and complex/existing blocks are edited in TextEdit, not rewritten by a
  parser. The app does not evaluate `Match exec` while inspecting config.
- **Diagnostics:** one explicit `ssh -T` test with batch authentication,
  connection timeout, strict existing host trust, no known-host writes,
  local command, or forwarding. It uses the main user config explicitly,
  not system SSH config, and `~/.ssh/known_hosts` only (not known_hosts2 or
  system host trust). Existing ProxyCommand/ProxyJump/Match exec rules may
  run during a test. The process is terminated after 15 seconds. Git hosts
  can report success with exit status 1; the host’s message is displayed.
  These tests do not establish HTTPS login or repository permissions.

Commit identity labels commits; SSH/HTTPS authenticate connections. The app
does not claim global settings are effective in every repository. Repository,
system, environment, and conditional include settings can override global
values. Global reads include unconditional includes; conditional repository
rules are evaluated only when you choose a folder for an identity check. Signing still requires a
working signing tool and key; this app does not install GPG or configure
allowed signers. Credential helpers are not proof of login.

## Safety and state

Every subprocess uses Foundation Process with argument arrays, asynchronous
execution, bounded captured output and a timeout. Nothing runs through a
shell. Git previews call `git config --file` on a private copy for a known
key allowlist (plus validated `alias.<name>`), then publish the reviewed
global file under Git’s `.lock` convention. `~/.gitconfig` is the default
write target; an existing XDG Git config is used when `.gitconfig` is absent,
and `GIT_CONFIG_GLOBAL` is respected. Profiles use the same staged Git edits;
rule editing uses Git to parse and validate config while changing only the
selected path assignment, adding section boundaries when its condition changes.
Config symlinks and oversized/nonregular files are refused for mutation.

Apply compares the original bytes again under a lock; stale previews refuse
to overwrite. Profile apply holds both the main config and profile locks and
also requires the main config to match the bytes that authorized the preview.
Profile restore requires those original main-config bytes too: any later rule
or main-config edit requires manual backup recovery. Timestamped before/after
backups live in
`~/.config/mac-utilities/git-settings/backups/` (directory 0700, files 0600).
They contain full configuration and should be treated as sensitive local
data. Restore compares all current bytes to the saved applied version and
refuses if any later edit exists, preserving unrelated subsequent work.
Backups remain for manual recovery in that case. No history is sent remotely.
The app neither starts/replaces an agent nor changes shell or launchd setup;
agent actions use the socket inherited by the app, with no Keychain
persistence. Refresh is manual and runs on launch; no periodic network tests.

## Development and isolated verification

```sh
swift build --package-path .
swift test --package-path .
```

The tests use per-test temporary directories, isolated HOME/XDG/global Git
config and no system Git config or SSH agent. They verify include preservation,
all four condition types, duplicate rule order/comment preservation, profile
creation and authorization, effective folder identity and local overrides,
source parsing, literal arguments, validation, stale preview/restore refusal,
backups, lock/symlink refusal, host scope preservation, key publication and
public inventory, and subprocess timeout/output limits. They never read
private-key contents or edit the host’s Git/SSH configuration.

For a UI fixture, launch the executable with `GIT_SETTINGS_HOME=/absolute/path`
pointing to an isolated directory. This forces HOME/XDG/global Git config,
disables system Git config, and clears SSH_AUTH_SOCK. Put fixture `.gitconfig`,
`.ssh/config` and public files there; writes/backups remain in that directory.
Use a fresh fixture for each run. Diagnostics are still real network actions
if you explicitly invoke them. The override is opt-in; ordinary launches use
the real user home. To verify staging without installing on the host:

```sh
GIT_SETTINGS_DISABLE_SANDBOX=1 ./scripts/install.sh /tmp/git-settings-review/Applications
GIT_SETTINGS_HOME=/tmp/git-settings-review/home \
  '/tmp/git-settings-review/Applications/Git & SSH.app/Contents/MacOS/GitSettings'
```

In restricted build environments use `--disable-sandbox` and writable module
caches via `CLANG_MODULE_CACHE_PATH=/tmp/git-settings-clang-cache` and
`SWIFT_MODULECACHE_PATH=/tmp/git-settings-swift-cache`; the installer sets
these caches automatically. Builds target the current Mac architecture.

Protocol references: [Git config](https://git-scm.com/docs/git-config),
[OpenSSH key generation](https://man.openbsd.org/ssh-keygen.1), and
[OpenSSH agent/askpass](https://man.openbsd.org/ssh-add.1).
