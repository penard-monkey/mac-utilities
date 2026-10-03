#!/usr/bin/python3
"""Manifest-driven Mac Utilities lifecycle. Python 3.9, standard library only."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid

CATALOG = [
    ("tools", "Tools", "Open your installed utilities from the menu bar."),
    ("memory", "Memory", "Memory pressure and usage in the menu bar."),
    ("travel-router", "Travel Router", "Travel networking; administrator setup in Terminal."),
    ("gif-stickers", "GIF Stickers", "Create and export animated stickers."),
    ("git-settings", "Git & SSH", "Manage Git identity and SSH connections."),
]
IGNORE = shutil.ignore_patterns(".git", ".worktrees", ".worktrees.places.json", ".build", ".swiftpm",
                               ".planning", "task_plan.md", "findings.md", "progress.md", "__pycache__", ".DS_Store")

class LifecycleError(Exception):
    pass

def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        temp.write_text(json.dumps(value, indent=2) + "\n")
        os.replace(str(temp), str(path))
    finally:
        if temp.exists():
            temp.unlink()

def digest(path):
    """Include paths, modes and symlink targets; never follow symlinks."""
    if not path.is_dir() or path.is_symlink():
        raise LifecycleError("Expected an owned directory: " + str(path))
    h = hashlib.sha256()
    for entry in sorted(path.rglob("*")):
        h.update(str(entry.relative_to(path)).encode() + b"\0")
        if entry.is_symlink():
            h.update(b"link\0" + os.readlink(str(entry)).encode())
        elif entry.is_file():
            h.update(b"file\0" + str(entry.stat().st_mode & 0o777).encode())
            with entry.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    h.update(block)
        elif entry.is_dir():
            h.update(b"dir\0")
        else:
            raise LifecycleError("Unsupported file: " + str(entry))
    return h.hexdigest()

def relative_path(value):
    if not isinstance(value, str) or not value or Path(value).is_absolute() or ".." in Path(value).parts:
        raise LifecycleError("Manifest paths must be relative and stay inside their utility: " + str(value))
    return Path(value)

def validate(manifest):
    if manifest.get("schema") != 1 or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", manifest.get("id", "")):
        raise LifecycleError("Invalid manifest schema or id")
    for key in ("name", "version", "description", "presentation"):
        if not isinstance(manifest.get(key), str) or not manifest[key]:
            raise LifecycleError("Manifest requires " + key)
    if manifest["presentation"] not in ("app", "plugin", "launcher"):
        raise LifecycleError("Unknown presentation")
    if not isinstance(manifest.get("privileged", False), bool):
        raise LifecycleError("privileged must be boolean")
    if "system_paths" in manifest:
        paths = manifest["system_paths"]
        if not manifest.get("privileged") or not isinstance(paths, list) or not paths or not all(
                isinstance(p, str) and Path(p).is_absolute() and ".." not in Path(p).parts and p != "/" for p in paths):
            raise LifecycleError("system_paths requires a privileged utility and a nonempty list of absolute file paths")
    if "app" in manifest:
        name = manifest["app"]["name"]
        if relative_path(name).name != name or not name.endswith(".app"):
            raise LifecycleError("App name must be a single .app filename")
        if not manifest.get("privileged", False) and "install" not in manifest:
            raise LifecycleError("App requires install command")
    if "plugin" in manifest:
        path = relative_path(manifest["plugin"]["path"])
        if not re.fullmatch(r".+\.[0-9]+[smhd]\.[^.]+", path.name) or path.suffix in (".md", ".json", ".txt"):
            raise LifecycleError("Plugin must follow SwiftBar name.interval.extension naming")
    for action in ("install", "uninstall"):
        if action in manifest:
            command = manifest[action].get("command")
            if not isinstance(command, list) or not command or not all(isinstance(v, str) for v in command):
                raise LifecycleError("Hook command must be an argument array")
            relative_path(command[0])
    for item in manifest.get("dependencies", []):
        if not all(isinstance(item.get(key), str) and item[key] for key in ("name", "help")):
            raise LifecycleError("Dependency requires name and help")
        if not isinstance(item.get("paths"), list) or not item["paths"] or not all(isinstance(p, str) and Path(p).is_absolute() for p in item["paths"]):
            raise LifecycleError("Dependency paths must be absolute")
    return manifest

class Manager:
    def __init__(self, repo, home, applications=None, system_effects=True, system_root="/"):
        self.repo = Path(repo).resolve()
        self.home = Path(home).expanduser().resolve()
        self.apps = Path(applications).expanduser().resolve() if applications else self.home / "Applications"
        self.root = self.home / "Library/Application Support/mac-utilities"
        self.payloads = self.root / "payloads"
        self.receipts = self.root / "state/receipts"
        self.config = self.home / ".config/mac-utilities"
        self.plugins = self.home / ".swiftbar"
        self.system_effects = system_effects
        self.system_root = Path(system_root)

    @contextlib.contextmanager
    def lock(self):
        self.root.mkdir(parents=True, exist_ok=True)
        with (self.root / "state.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def git_common_dir(self, directory):
        try:
            value = subprocess.check_output(["/usr/bin/git", "-C", str(directory), "rev-parse", "--git-common-dir"],
                                            stderr=subprocess.DEVNULL, text=True).strip()
            return (Path(directory) / value).resolve()
        except (OSError, subprocess.CalledProcessError):
            return None

    def legacy_link(self, source, manifest):
        if "plugin" not in manifest:
            return None
        path = self.plugins / Path(manifest["plugin"]["path"]).name
        if not path.is_symlink():
            return None
        target = path.resolve()
        catalog_source = self.catalog_source(source)
        expected = self.git_common_dir(catalog_source)
        origin = catalog_source / "catalog-origin.json"
        if expected is None and origin.is_file():
            expected = Path(json.loads(origin.read_text())["git_common_dir"]).resolve()
        # Both utility-relative path and the shared git repository must match.
        relative = source.relative_to(catalog_source) / manifest["plugin"]["path"]
        if expected is None or not target.is_file():
            return None
        if str(target).endswith("/" + str(relative)) and self.git_common_dir(target.parent) == expected:
            return os.readlink(str(path))
        return None

    def external_status(self, manifest):
        return bool(manifest and manifest.get("privileged") and any(
            (self.system_root / p.lstrip("/")).exists() for p in manifest.get("system_paths", [])))

    def dependencies(self, manifest):
        missing = []
        for item in (manifest or {}).get("dependencies", []):
            if not any(Path(p).is_file() and os.access(p, os.X_OK) for p in item["paths"]):
                missing.append(item["name"] + ": " + item["help"])
        return missing

    def source_paths(self):
        path = self.config / "sources.json"
        if not path.exists():
            return []
        values = json.loads(path.read_text())
        if not isinstance(values, list) or not all(isinstance(v, str) and v for v in values):
            raise LifecycleError("sources.json must be a JSON array of directory paths")
        result = []
        for value in values:
            directory = Path(value).expanduser()
            if not directory.is_absolute():
                raise LifecycleError("Catalog source paths must be absolute: " + value)
            directory = directory.resolve()
            if directory != self.repo and directory not in result:
                result.append(directory)
        return result

    def sources(self):
        return [{"path": str(p), "primary": p == self.repo, "available": p.is_dir()}
                for p in [self.repo] + self.source_paths()]

    def catalog_source(self, utility):
        for directory in sorted([self.repo] + self.source_paths(), key=lambda p: len(p.parts), reverse=True):
            if utility == directory or directory in utility.parents:
                return directory
        raise LifecycleError("Utility is outside the configured catalog sources: " + str(utility))

    def change_source(self, action, value):
        if action not in ("add", "remove") or not value:
            raise LifecycleError("source requires list, add <directory>, or remove <directory>")
        directory = Path(value).expanduser().resolve()
        sources = self.source_paths()
        if directory == self.repo:
            raise LifecycleError("The primary source is selected with --repo or Choose folder in the app")
        if action == "add":
            if not directory.is_dir():
                raise LifecycleError("Source directory does not exist: " + str(directory))
            if directory not in sources:
                candidate = sources + [directory]
                manifests = self.manifests(roots=[self.repo] + candidate)
                if not any(source == directory or directory in source.parents for _, source in manifests.values()):
                    raise LifecycleError("No utility manifests found in " + str(directory))
                sources = candidate
        else:
            sources = [p for p in sources if p != directory]
        atomic_json(self.config / "sources.json", [str(p) for p in sources])
        return {"message": "Catalog source " + ("added" if action == "add" else "removed"), "sources": self.sources()}

    def manifests(self, roots=None):
        result = {}
        # Only documented utility shapes; no walk into worktrees/build directories.
        seen = set()
        for root in roots if roots is not None else [self.repo] + self.source_paths():
            paths = list(root.glob("*/mac-utility.json")) + list(root.glob("swiftbar/*/mac-utility.json"))
            if (root / "mac-utility.json").is_file():
                paths.append(root / "mac-utility.json")
            for path in sorted(paths):
                if path.resolve() in seen:
                    continue
                seen.add(path.resolve())
                manifest = validate(json.loads(path.read_text()))
                if manifest["id"] in result:
                    raise LifecycleError("Duplicate manifest id: " + manifest["id"] + " in " +
                                         str(result[manifest["id"]][1]) + " and " + str(path.parent))
                result[manifest["id"]] = (manifest, path.parent)
        return result

    def receipt(self, utility_id):
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", utility_id):
            raise LifecycleError("Invalid utility id")
        path = self.receipts / (utility_id + ".json")
        if not path.exists():
            return None
        record = json.loads(path.read_text())
        if record.get("schema") != 1 or record.get("id") != utility_id:
            raise LifecycleError("Invalid ownership receipt: " + str(path))
        if Path(record["payload"]) != self.payloads / utility_id:
            raise LifecycleError("Receipt payload is outside the owned location")
        manifest = validate(record["manifest"])
        if manifest["id"] != utility_id:
            raise LifecycleError("Receipt manifest id mismatch")
        if record.get("app") and Path(record["app"]) != self.apps / manifest["app"]["name"]:
            raise LifecycleError("Receipt app is outside the selected Applications directory")
        if record.get("plugin"):
            plugin = record["plugin"]
            if Path(plugin["path"]) != self.plugins / Path(manifest["plugin"]["path"]).name:
                raise LifecycleError("Receipt plugin path is outside ~/.swiftbar")
            if Path(plugin["target"]) != Path(record["payload"]) / manifest["plugin"]["path"]:
                raise LifecycleError("Receipt plugin target is outside owned payload")
        return record

    def verify(self, record):
        for key in ("payload", "app"):
            if record.get(key):
                path = Path(record[key])
                if not path.exists() or digest(path) != record[key + "_digest"]:
                    raise LifecycleError("Owned " + key + " was changed or removed; leaving files alone: " + str(path))
        if record.get("plugin"):
            plugin = record["plugin"]
            path = Path(plugin["path"])
            if path.is_symlink():
                if os.readlink(str(path)) != plugin["target"]:
                    raise LifecycleError("Plugin link belongs to another installation: " + str(path))
            elif path.exists():
                raise LifecycleError("Plugin path contains an unrelated file: " + str(path))
            elif record.get("visible"):
                raise LifecycleError("Owned plugin link was removed: " + str(path))

    def privileged_commands(self, record):
        if not record["manifest"].get("privileged"):
            return {}
        return {action: "sudo " + shlex.join([str(Path(record["payload"]) / hook["command"][0])] + hook["command"][1:])
                for action in ("install", "uninstall") for hook in [record["manifest"].get(action)] if hook}

    def catalog(self):
        available = self.manifests()
        entries = []
        installed = {p.stem for p in self.receipts.glob("*.json")}
        ids = [v[0] for v in CATALOG] + sorted((set(available) | installed) - {v[0] for v in CATALOG})
        defaults = {v[0]: v for v in CATALOG}
        for utility_id in ids:
            record = self.receipt(utility_id)
            manifest = available.get(utility_id, (None, None))[0] or (record["manifest"] if record else None)
            fallback = defaults.get(utility_id, (utility_id, utility_id, ""))
            healthy, issue = True, None
            if record:
                try:
                    self.verify(record)
                except LifecycleError as error:
                    healthy, issue = False, str(error)
            entries.append({
                "id": utility_id, "name": manifest["name"] if manifest else fallback[1],
                "description": manifest["description"] if manifest else fallback[2],
                "available": utility_id in available, "installed": record is not None,
                "source": str(self.catalog_source(available[utility_id][1])) if utility_id in available else (record.get("source") if record else None),
                "healthy": healthy, "issue": issue,
                "version": record["version"] if record else None,
                "available_version": available[utility_id][0]["version"] if utility_id in available else None,
                "presentation": manifest["presentation"] if manifest else "app",
                "visible": record.get("visible", False) if record else False,
                "app": record.get("app") if record else None,
                "privileged": manifest.get("privileged", False) if manifest else False,
                "commands": self.privileged_commands(record) if record else {},
                "system_detected": self.external_status(manifest),
                "legacy_plugin": bool(self.legacy_link(available[utility_id][1], manifest)) if utility_id in available and not record else False,
                "external_app": str(self.apps / manifest["app"]["name"]) if manifest and "app" in manifest and not record and (self.apps / manifest["app"]["name"]).exists() else None,
                "missing_dependencies": self.dependencies(manifest),
            })
        return entries

    def write_launcher(self):
        entries = []
        if self.receipts.exists():
            for path in sorted(self.receipts.glob("*.json")):
                record = self.receipt(path.stem)
                if record and record.get("app"):
                    entries.append({"id": record["id"], "name": record["manifest"]["name"],
                                    "app": record["app"], "visible": record["visible"]})
        atomic_json(self.config / "installed-tools.json", entries)

    def refresh(self):
        if self.system_effects:
            # Only the user's actual home may affect SwiftBar.
            if self.home != Path.home().resolve():
                raise LifecycleError("Alternate homes require --no-system-effects")
            subprocess.run(["/usr/bin/defaults", "write", "com.ameba.SwiftBar", "PluginDirectory", str(self.plugins)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            subprocess.run(["/usr/bin/open", "-g", "swiftbar://refreshallplugins"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

    def install(self, utility_id):
        available = self.manifests()
        if utility_id not in available:
            raise LifecycleError("Source is unavailable for " + utility_id + ". Choose a checkout or add its utility repository.")
        manifest, source = available[utility_id]
        previous = self.receipt(utility_id)
        if previous:
            self.verify(previous)
            # Contract migrations must not silently leave an old app or link behind.
            for key in ("app", "plugin"):
                if previous["manifest"].get(key) != manifest.get(key):
                    raise LifecycleError("Presentation paths changed; uninstall the owned utility before reinstalling")
        destination = self.payloads / utility_id
        app = self.apps / manifest["app"]["name"] if "app" in manifest else None
        plugin = self.plugins / Path(manifest["plugin"]["path"]).name if "plugin" in manifest else None
        legacy = self.legacy_link(source, manifest) if not previous else None
        if not previous:
            for path in (destination, app, plugin):
                if path == plugin and legacy:
                    continue
                if path and (path.exists() or path.is_symlink()):
                    raise LifecycleError("Unowned destination already exists; leaving it alone: " + str(path))
        self.root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="stage-", dir=str(self.root)) as work:
            stage = Path(work)
            payload = stage / "payload"
            shutil.copytree(str(source), str(payload), symlinks=True, ignore=IGNORE)
            # Source symlinks are kept only if they stay within the utility.
            for path in payload.rglob("*"):
                if path.is_symlink():
                    try:
                        path.resolve().relative_to(payload.resolve())
                    except ValueError:
                        raise LifecycleError("Payload symlink escapes its utility: " + str(path))
            if plugin:
                script = payload / manifest["plugin"]["path"]
                if not script.is_file() or not os.access(str(script), os.X_OK):
                    raise LifecycleError("SwiftBar plugin must exist and be executable: " + str(script))
            stage_apps = stage / "Applications"
            stage_apps.mkdir()
            if "install" in manifest and not manifest.get("privileged", False):
                command = manifest["install"]["command"]
                hook = payload / command[0]
                if not hook.is_file() or not os.access(str(hook), os.X_OK):
                    raise LifecycleError("Install hook is missing or not executable: " + str(hook))
                args = [str(hook)] + [v.replace("{applications}", str(stage_apps)) for v in command[1:]]
                env = dict(os.environ, HOME=str(self.home), PATH="/usr/bin:/bin:/usr/sbin:/sbin")
                result = subprocess.run(args, cwd=str(payload), env=env, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True)
                if result.returncode:
                    raise LifecycleError("Install hook failed (existing install kept):\n" + result.stdout[-16000:])
            staged_app = stage_apps / app.name if app else None
            if app and (not staged_app.is_dir() or staged_app.is_symlink()):
                raise LifecycleError("Installer did not produce " + app.name)
            # Build products stay out of the installed source snapshot.
            for name in (".build", ".swiftpm"):
                build = payload / name
                if build.is_dir() and not build.is_symlink():
                    shutil.rmtree(str(build))
            record = {"schema": 1, "id": utility_id, "version": manifest["version"], "manifest": manifest,
                      "source": str(self.catalog_source(source)),
                      "payload": str(destination), "payload_digest": digest(payload),
                      "visible": previous["visible"] if previous else True}
            if legacy:
                record["legacy_plugin_target"] = legacy
            elif previous and previous.get("legacy_plugin_target"):
                record["legacy_plugin_target"] = previous["legacy_plugin_target"]
            if app:
                record.update(app=str(app), app_digest=digest(staged_app))
            if plugin:
                record["plugin"] = {"path": str(plugin), "target": str(destination / manifest["plugin"]["path"])}
            # Re-check after a potentially long build, before replacing anything.
            if previous:
                self.verify(previous)
            else:
                for path in (destination, app, plugin):
                    if path == plugin and legacy and path.is_symlink() and os.readlink(str(path)) == legacy:
                        continue
                    if path and (path.exists() or path.is_symlink()):
                        raise LifecycleError("Destination appeared during build: " + str(path))
            moves = []
            old_link = os.readlink(str(plugin)) if plugin and plugin.is_symlink() else None
            receipt_path = self.receipts / (utility_id + ".json")
            try:
                for src, dst in [(payload, destination)] + ([(staged_app, app)] if app else []):
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    backup = stage / ("backup-" + str(len(moves)))
                    had_previous = dst.exists()
                    if had_previous:
                        os.replace(str(dst), str(backup))
                    moves.append((dst, backup, had_previous))
                    os.replace(str(src), str(dst))
                if plugin:
                    self.plugins.mkdir(parents=True, exist_ok=True)
                    if plugin.is_symlink():
                        plugin.unlink()
                    if record["visible"]:
                        plugin.symlink_to(record["plugin"]["target"])
                atomic_json(receipt_path, record)
                self.write_launcher()
            except Exception:
                if plugin and plugin.is_symlink() and os.readlink(str(plugin)) == record["plugin"]["target"]:
                    plugin.unlink()
                if old_link and plugin and not plugin.exists() and not plugin.is_symlink():
                    plugin.symlink_to(old_link)
                for dst, backup, had_previous in reversed(moves):
                    if dst.exists():
                        shutil.rmtree(str(dst))
                    if had_previous:
                        os.replace(str(backup), str(dst))
                if previous:
                    atomic_json(receipt_path, previous)
                elif receipt_path.exists():
                    receipt_path.unlink()
                raise
        self.refresh()
        return {"message": "Installed " + manifest["name"] + (". System setup requires the Terminal command shown in the manager." if manifest.get("privileged") else ""),
                "commands": self.privileged_commands(record)}

    def visibility(self, utility_id, visible):
        record = self.receipt(utility_id)
        if not record:
            raise LifecycleError("Install the utility before changing menu visibility")
        self.verify(record)
        previous = dict(record)
        path = Path(record["plugin"]["path"]) if record.get("plugin") else None
        old_link = os.readlink(str(path)) if path and path.is_symlink() else None
        receipt_path = self.receipts / (utility_id + ".json")
        try:
            if path:
                if path.is_symlink():
                    path.unlink()
                if visible:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.symlink_to(record["plugin"]["target"])
            record["visible"] = visible
            atomic_json(receipt_path, record)
            self.write_launcher()
        except Exception:
            if path and path.is_symlink() and os.readlink(str(path)) == record["plugin"]["target"]:
                path.unlink()
            if path and old_link and not path.exists() and not path.is_symlink():
                path.symlink_to(old_link)
            atomic_json(receipt_path, previous)
            raise
        self.refresh()
        return {"message": "Menu visibility updated"}

    def uninstall(self, utility_id):
        record = self.receipt(utility_id)
        if not record:
            return {"message": "Already uninstalled"}
        self.verify(record)
        if record["manifest"].get("privileged"):
            raise LifecycleError(record["manifest"]["name"] + " system services must be removed in Terminal first. Run the supplied uninstall command, then use 'forget-system' to remove the staged payload. Preferences are retained.")
        return self.remove_owned(record)

    def remove_owned(self, record):
        self.verify(record)
        plugin = Path(record["plugin"]["path"]) if record.get("plugin") else None
        old_link = os.readlink(str(plugin)) if plugin and plugin.is_symlink() else None
        receipt_path = self.receipts / (record["id"] + ".json")
        with tempfile.TemporaryDirectory(prefix="remove-", dir=str(self.root)) as work:
            moved = []
            try:
                if old_link:
                    plugin.unlink()
                for key in ("app", "payload"):
                    if record.get(key):
                        original = Path(record[key])
                        backup = Path(work) / key
                        os.replace(str(original), str(backup))
                        moved.append((original, backup))
                receipt_path.unlink()
                self.write_launcher()
            except Exception:
                for original, backup in reversed(moved):
                    os.replace(str(backup), str(original))
                if old_link and not plugin.exists() and not plugin.is_symlink():
                    plugin.symlink_to(old_link)
                atomic_json(receipt_path, record)
                raise
        self.refresh()
        return {"message": "Removed managed files; preferences and keys retained"}

    def forget_system(self, utility_id):
        record = self.receipt(utility_id)
        if not record or not record["manifest"].get("privileged"):
            raise LifecycleError("forget-system is only for staged privileged utilities")
        # A privileged uninstaller may have removed our symlink itself.
        plugin = record.get("plugin")
        if plugin and not Path(plugin["path"]).exists() and not Path(plugin["path"]).is_symlink():
            record["visible"] = False
        return self.remove_owned(record)

    def run_terminal(self, utility_id, action):
        record = self.receipt(utility_id)
        if not record:
            raise LifecycleError("Stage the utility first")
        self.verify(record)
        command = self.privileged_commands(record).get(action)
        if not command:
            raise LifecycleError("No privileged command for this action")
        if not self.system_effects:
            return {"message": "Terminal suppressed for isolated home", "command": command}
        path = self.root / "state/terminal" / (utility_id + "-" + action + ".command")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/bash\n" + command + "\nstatus=$?\nprintf '\\nCommand finished with status %s. Press Return to close.\\n' \"$status\"\nread -r _\nexit \"$status\"\n")
        path.chmod(0o700)
        subprocess.run(["/usr/bin/open", "-a", "Terminal", str(path)], check=True)
        return {"message": "Opened command in Terminal. Review its output before continuing."}

    def open_app(self, utility_id):
        record = self.receipt(utility_id)
        if not record or not record.get("app"):
            raise LifecycleError("This utility has no installed app")
        self.verify(record)
        if not self.system_effects:
            return {"message": "App path", "app": record["app"]}
        subprocess.run(["/usr/bin/open", record["app"]], check=True)
        return {"message": "Opened " + record["manifest"]["name"]}

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--home", default=str(Path.home()))
    parser.add_argument("--applications")
    parser.add_argument("--no-system-effects", action="store_true")
    parser.add_argument("action", choices=("list", "source", "install", "update", "uninstall", "menu", "open", "forget-system", "run-terminal"))
    parser.add_argument("id", nargs="?")
    parser.add_argument("value", nargs="?")
    args = parser.parse_args(argv)
    try:
        manager = Manager(args.repo, args.home, args.applications, not args.no_system_effects)
        if manager.system_effects and manager.home != Path.home().resolve():
            raise LifecycleError("Alternate homes require --no-system-effects")
        if args.action not in ("list", "source") and not args.id:
            raise LifecycleError("Select a utility id")
        with manager.lock():
            if args.action == "list":
                result = {"utilities": manager.catalog(), "repo": str(manager.repo), "sources": manager.sources()}
            elif args.action == "source":
                result = {"sources": manager.sources()} if args.id in (None, "list") else manager.change_source(args.id, args.value)
            elif args.action in ("install", "update"):
                result = manager.install(args.id)
            elif args.action == "menu":
                if args.value not in ("show", "hide"):
                    raise LifecycleError("menu requires show or hide")
                result = manager.visibility(args.id, args.value == "show")
            elif args.action == "run-terminal":
                if args.value not in ("install", "uninstall"):
                    raise LifecycleError("run-terminal requires install or uninstall")
                result = manager.run_terminal(args.id, args.value)
            else:
                method = "open_app" if args.action == "open" else args.action.replace("-", "_")
                result = getattr(manager, method)(args.id)
        print(json.dumps(result))
        return 0
    except (LifecycleError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(json.dumps({"error": str(error)}))
        return 1

if __name__ == "__main__":
    sys.exit(main())
