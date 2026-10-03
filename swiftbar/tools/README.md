# Tools (SwiftBar)

One menu-bar entry launches independent native Mac utility apps. GIF Stickers
and Git & SSH open their own windows. Memory and Travel Router keep their own
status items. **Manage Utilities…** opens `~/Applications/Mac Utilities.app`
for installation, removal and visibility settings.

The selective installer maintains
`~/.config/mac-utilities/installed-tools.json`, a list of records with `name`,
`app`, optional `id`, and `visible` (a boolean, default true). Installed payloads
live outside development worktrees. Keep SwiftBar pointed at `~/.swiftbar`.

## Custom launchers

Choose **Edit Custom Tools…** to create/open
`~/.config/mac-utilities/tools.json` in your text editor. Add one entry per app:

```json
[
  {"name": "Another Tool", "app": "~/Applications/Another Tool.app"}
]
```

Save and choose **Refresh** (the menu also refreshes every minute). Managed
entries appear first, followed by custom entries; duplicate app paths appear
once. Hiding a managed app also suppresses a custom entry for the same path.
An app that is not installed appears as a gray status row. Invalid configuration
shows an error without hiding entries from the other configuration file.

Without either configuration file, GIF Stickers is the legacy default. Once
an installed-tools catalog exists, its entries determine the managed launchers,
including when the catalog is empty.

Apps are opened with `/usr/bin/open` using argument arrays; menu refresh never
runs background jobs or shell commands. The system Python 3.9 and standard
library are sufficient. The SF Symbol and text colors adapt to light/dark mode.

Development:

```sh
swiftbar/tools/tools.1m.py
/usr/bin/python3 -m unittest discover -s swiftbar/tools/tests -v
```
