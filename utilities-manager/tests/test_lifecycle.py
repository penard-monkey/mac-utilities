import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest
from unittest.mock import patch

BACKEND = Path(__file__).resolve().parents[1] / "backend/lifecycle.py"
ROOT_SCRIPT = BACKEND.parents[2] / "scripts/install.sh"
spec = importlib.util.spec_from_file_location("lifecycle", BACKEND)
lifecycle = importlib.util.module_from_spec(spec)
sys.modules["lifecycle"] = lifecycle
spec.loader.exec_module(lifecycle)

class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.home = self.base / "home with spaces"
        self.home.mkdir()
        self.manager = lifecycle.Manager(self.repo, self.home, system_effects=False, system_root=self.base / "system")

    def tearDown(self):
        self.temp.cleanup()

    def utility(self, utility_id="memory", app=False, privileged=False):
        source = self.repo / utility_id
        source.mkdir()
        manifest = {"schema": 1, "id": utility_id, "name": utility_id.title(), "version": "1.0.0",
                    "description": "Testing", "presentation": "app" if app else "plugin", "privileged": privileged}
        if app:
            manifest["app"] = {"name": "Sample Utility.app", "bundle_id": "com.example.sample"}
            manifest["install"] = {"command": ["scripts/install.sh", "{applications}"]}
            hook = source / "scripts/install.sh"
            hook.parent.mkdir()
            hook.write_text('#!/bin/bash\nset -eu\nmkdir -p "$1/Sample Utility.app/Contents/MacOS"\nprintf app > "$1/Sample Utility.app/Contents/MacOS/Sample"\n')
            hook.chmod(0o755)
        else:
            plugin = source / ("test.5s.py" if utility_id == "memory" else utility_id + ".5s.py")
            plugin.write_text("#!/usr/bin/python3\nprint('ok')\n")
            plugin.chmod(0o755)
            manifest["plugin"] = {"path": plugin.name}
        if privileged:
            manifest["system_paths"] = ["/usr/local/sbin/test-service", "/Library/LaunchDaemons/com.example.test.plist"]
            manifest["install"] = {"command": ["scripts/install.sh"]}
            manifest["uninstall"] = {"command": ["scripts/uninstall.sh"]}
            for action in ("install", "uninstall"):
                hook = source / "scripts" / (action + ".sh")
                hook.parent.mkdir(exist_ok=True)
                hook.write_text("#!/bin/bash\ntouch " + str(self.base / "MUST_NOT_RUN") + "\nexit 1\n")
                hook.chmod(0o755)
        (source / "mac-utility.json").write_text(json.dumps(manifest))
        return source, manifest

    def test_catalog_update_available_only_when_catalog_is_strictly_newer(self):
        source, manifest = self.utility()
        def flag():
            return next(e for e in self.manager.catalog() if e["id"] == "memory")["update_available"]
        self.assertFalse(flag())  # available but not installed
        self.manager.install("memory")
        self.assertFalse(flag())  # equal
        for version, expected in (("1.0.1", True), ("1.10.0", True), ("0.9.9", False)):
            manifest["version"] = version
            (source / "mac-utility.json").write_text(json.dumps(manifest))
            self.assertEqual(flag(), expected, version)
        manifest["version"] = "1.0.0"
        (source / "mac-utility.json").write_text(json.dumps(manifest))
        self.assertFalse(flag())
        # Installed but gone from the catalog: nothing to update to.
        (source / "mac-utility.json").unlink()
        self.assertFalse(flag())

    def test_plugin_stable_install_update_visibility_uninstall_preserves_preferences(self):
        source, manifest = self.utility()
        prefs = self.manager.config / "memory.json"
        prefs.parent.mkdir(parents=True)
        prefs.write_text("preferences")
        cache = self.home / ".cache/mac-utilities/memory.json"
        cache.parent.mkdir(parents=True)
        cache.write_text("history")
        self.manager.install("memory")
        link = self.manager.plugins / "test.5s.py"
        self.assertEqual(link.resolve(), self.manager.payloads / "memory/test.5s.py")
        self.assertNotIn(str(self.repo), str(link.resolve()))
        self.manager.visibility("memory", False)
        self.assertFalse(link.is_symlink())
        self.assertTrue(self.manager.receipt("memory"))
        (source / "test.5s.py").write_text("#!/usr/bin/python3\nprint('updated')\n")
        self.manager.install("memory")
        self.assertFalse(self.manager.receipt("memory")["visible"])
        self.assertIn("updated", (self.manager.payloads / "memory/test.5s.py").read_text())
        self.manager.visibility("memory", True)
        self.manager.uninstall("memory")
        self.assertFalse(link.is_symlink())
        self.assertFalse((self.manager.payloads / "memory").exists())
        self.assertEqual(prefs.read_text(), "preferences")
        self.assertEqual(cache.read_text(), "history")

    def test_foreign_plugin_and_app_are_not_overwritten(self):
        self.utility()
        self.manager.plugins.mkdir()
        link = self.manager.plugins / "test.5s.py"
        link.write_text("unrelated")
        with self.assertRaises(lifecycle.LifecycleError): self.manager.install("memory")
        self.assertEqual(link.read_text(), "unrelated")
        link.unlink()
        self.utility("gif-stickers", app=True)
        app = self.manager.apps / "Sample Utility.app"
        app.mkdir(parents=True)
        (app / "keep").write_text("unrelated")
        with self.assertRaises(lifecycle.LifecycleError): self.manager.install("gif-stickers")
        self.assertEqual((app / "keep").read_text(), "unrelated")

    def test_changed_owned_directory_prevents_uninstall_and_update(self):
        self.utility("gif-stickers", app=True)
        self.manager.install("gif-stickers")
        receipt = self.manager.receipt("gif-stickers")
        file = Path(receipt["app"]) / "foreign-note"
        file.write_text("keep")
        with self.assertRaises(lifecycle.LifecycleError): self.manager.uninstall("gif-stickers")
        with self.assertRaises(lifecycle.LifecycleError): self.manager.install("gif-stickers")
        self.assertEqual(file.read_text(), "keep")
        entry = next(u for u in self.manager.catalog() if u["id"] == "gif-stickers")
        self.assertFalse(entry["healthy"])
        self.assertIn("changed", entry["issue"])

    def test_repointed_or_dangling_foreign_link_is_preserved(self):
        self.utility()
        self.manager.install("memory")
        link = self.manager.plugins / "test.5s.py"
        link.unlink()
        link.symlink_to(self.base / "nonexistent-foreign")
        with self.assertRaises(lifecycle.LifecycleError): self.manager.uninstall("memory")
        self.assertEqual(os.readlink(link), str(self.base / "nonexistent-foreign"))

    def test_app_launcher_visibility_open_dispatch_and_user_settings(self):
        self.utility("gif-stickers", app=True)
        keys = self.home / ".ssh/id_ed25519"
        keys.parent.mkdir()
        keys.write_text("private key test fixture")
        custom = self.manager.config / "tools.json"
        custom.parent.mkdir(parents=True)
        custom.write_text("custom apps")
        self.manager.install("gif-stickers")
        self.manager.visibility("gif-stickers", False)
        entries = json.loads((self.manager.config / "installed-tools.json").read_text())
        self.assertEqual(entries[0]["visible"], False)
        self.assertEqual(entries[0]["app"], str(self.manager.apps / "Sample Utility.app"))
        result = self.cli("open", "gif-stickers")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(json.loads(result.stdout)["app"], entries[0]["app"])
        self.manager.uninstall("gif-stickers")
        self.assertEqual(json.loads((self.manager.config / "installed-tools.json").read_text()), [])
        self.assertEqual(custom.read_text(), "custom apps")
        self.assertEqual(keys.read_text(), "private key test fixture")

    def cli(self, *args):
        return subprocess.run(["/usr/bin/python3", str(BACKEND), "--repo", str(self.repo), "--home", str(self.home),
                               "--no-system-effects"] + list(args), stdout=subprocess.PIPE, text=True)

    def test_hook_failure_keeps_previous_app_and_receipt(self):
        source, manifest = self.utility("gif-stickers", app=True)
        self.manager.install("gif-stickers")
        previous = self.manager.receipt("gif-stickers")
        (source / "scripts/install.sh").write_text("#!/bin/bash\nprintf 'build failed'\nexit 4\n")
        with self.assertRaisesRegex(lifecycle.LifecycleError, "build failed"):
            self.manager.install("gif-stickers")
        self.assertEqual(self.manager.receipt("gif-stickers"), previous)
        self.manager.verify(previous)

    def test_transaction_rollback_after_publish_failure(self):
        self.utility("gif-stickers", app=True)
        self.manager.install("gif-stickers")
        previous = self.manager.receipt("gif-stickers")
        with patch.object(self.manager, "write_launcher", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                self.manager.install("gif-stickers")
        self.assertEqual(self.manager.receipt("gif-stickers"), previous)
        self.manager.verify(previous)

    def test_uninstall_and_visibility_roll_back_after_metadata_failure(self):
        self.utility()
        self.manager.install("memory")
        previous = self.manager.receipt("memory")
        with patch.object(self.manager, "write_launcher", side_effect=OSError("disk full")):
            for action in (lambda: self.manager.visibility("memory", False), lambda: self.manager.uninstall("memory")):
                with self.assertRaisesRegex(OSError, "disk full"):
                    action()
                self.assertEqual(self.manager.receipt("memory"), previous)
                self.manager.verify(previous)

    def test_privileged_hooks_never_run_and_system_detection_separate(self):
        self.utility("travel-router", privileged=True)
        system = self.manager.system_root / "usr/local/sbin/test-service"
        system.parent.mkdir(parents=True)
        system.write_text("external")
        result = self.manager.install("travel-router")
        self.assertFalse((self.base / "MUST_NOT_RUN").exists())
        self.assertIn("sudo", result["commands"]["install"])
        entry = next(u for u in self.manager.catalog() if u["id"] == "travel-router")
        self.assertTrue(entry["system_detected"])
        with self.assertRaisesRegex(lifecycle.LifecycleError, "Terminal"):
            self.manager.uninstall("travel-router")
        self.assertIn("suppressed", self.manager.run_terminal("travel-router", "install")["message"])
        # The existing privileged uninstaller may have removed the plugin first.
        (self.manager.plugins / "travel-router.5s.py").unlink()
        self.manager.forget_system("travel-router")
        self.assertTrue(system.exists())

    def external(self, utility_id="external-tool", root_manifest=True):
        source, manifest = self.utility(utility_id)
        directory = self.base / (utility_id + " repository")
        directory.mkdir()
        target = directory if root_manifest else directory / "swiftbar" / utility_id
        if not root_manifest:
            target.mkdir(parents=True)
        for path in source.iterdir():
            path.rename(target / path.name)
        source.rmdir()
        return directory, target, manifest

    def test_sources_root_and_swiftbar_manifests_install_update_and_remove(self):
        directory, source, manifest = self.external()
        nested, _, _ = self.external("nested-tool", root_manifest=False)
        for folder in (directory, nested):
            result = self.cli("source", "add", str(folder))
            self.assertEqual(result.returncode, 0, result.stdout)
        entry = next(u for u in self.manager.catalog() if u["id"] == "external-tool")
        self.assertEqual(entry["source"], str(directory))
        self.assertTrue(entry["available"])
        worktree_file = directory / ".worktrees/other/private.txt"
        worktree_file.parent.mkdir(parents=True)
        worktree_file.write_text("development state must not enter payloads")
        self.manager.install("external-tool")
        self.assertFalse((self.manager.payloads / "external-tool/.worktrees").exists())
        plugin = self.manager.plugins / manifest["plugin"]["path"]
        self.assertEqual(plugin.resolve(), self.manager.payloads / "external-tool" / plugin.name)
        (source / plugin.name).write_text("#!/usr/bin/python3\nprint('external update')\n")
        self.manager.install("external-tool")
        self.assertIn("external update", plugin.read_text())
        result = self.cli("source", "remove", str(directory))
        self.assertEqual(result.returncode, 0, result.stdout)
        entry = next(u for u in self.manager.catalog() if u["id"] == "external-tool")
        self.assertFalse(entry["available"])
        self.assertTrue(entry["installed"])
        self.assertEqual(entry["source"], str(directory))
        self.manager.uninstall("external-tool")
        self.assertFalse(plugin.is_symlink())
        self.assertIn("nested-tool", self.manager.manifests())
        self.assertEqual(self.manager.manifests(roots=[self.repo]), {})

    def test_id_clashes_report_both_sources_and_do_not_change_config(self):
        self.utility()
        directory, _, _ = self.external("other")
        path = directory / "mac-utility.json"
        manifest = json.loads(path.read_text())
        manifest["id"] = "memory"
        path.write_text(json.dumps(manifest))
        result = self.cli("source", "add", str(directory))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Duplicate manifest id: memory", result.stdout)
        self.assertIn(str(directory), result.stdout)
        self.assertIn(str(self.repo / "memory"), result.stdout)
        self.assertFalse((self.manager.config / "sources.json").exists())
        lifecycle.atomic_json(self.manager.config / "sources.json", [str(directory)])
        with self.assertRaisesRegex(lifecycle.LifecycleError, "Duplicate manifest id"):
            self.manager.catalog()
        self.assertEqual(self.cli("source", "list").returncode, 0)
        self.assertEqual(self.cli("source", "remove", str(directory)).returncode, 0)
        self.assertIn("memory", self.manager.manifests())

    def test_source_validation_missing_folder_and_canonical_duplicates(self):
        directory, _, _ = self.external()
        self.manager.change_source("add", str(directory))
        alias = self.base / "alias"
        alias.symlink_to(directory)
        self.manager.change_source("add", str(alias))
        self.assertEqual(self.manager.source_paths(), [directory])
        moved = self.base / "moved"
        directory.rename(moved)
        self.assertFalse(self.manager.sources()[1]["available"])
        self.assertNotIn("external-tool", self.manager.manifests())
        self.manager.change_source("remove", str(directory))
        with self.assertRaises(lifecycle.LifecycleError):
            self.manager.change_source("add", str(directory))
        with self.assertRaisesRegex(lifecycle.LifecycleError, "No utility manifests"):
            self.manager.change_source("add", str(self.home))
        for invalid in ({"sources": []}, [3], ["relative/path"]):
            lifecycle.atomic_json(self.manager.config / "sources.json", invalid)
            with self.assertRaises(lifecycle.LifecycleError): self.manager.manifests()

    def test_external_legacy_plugin_migration_matches_its_repository(self):
        directory, source, manifest = self.external()
        subprocess.run(["/usr/bin/git", "init", str(directory)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.manager.change_source("add", str(directory))
        self.manager.plugins.mkdir()
        plugin = self.manager.plugins / manifest["plugin"]["path"]
        plugin.symlink_to(source / plugin.name)
        self.assertTrue(next(u for u in self.manager.catalog() if u["id"] == manifest["id"])["legacy_plugin"])
        self.manager.install(manifest["id"])
        self.assertEqual(plugin.resolve(), self.manager.payloads / manifest["id"] / plugin.name)

    def test_system_paths_are_manifest_specific_and_validated(self):
        _, manifest = self.utility("service", privileged=True)
        system = self.manager.system_root / "Library/LaunchDaemons/com.example.test.plist"
        system.parent.mkdir(parents=True)
        system.write_text("service")
        self.assertTrue(self.manager.external_status(manifest))
        self.assertFalse(self.manager.external_status(dict(manifest, system_paths=["/different/service"])))
        self.assertFalse(self.manager.external_status(dict(manifest, system_paths=[])))
        for invalid in ("/absolute/file", [], ["relative/file"], ["/../escape"], [3], ["/"]):
            with self.assertRaisesRegex(lifecycle.LifecycleError, "system_paths"):
                lifecycle.validate(dict(manifest, system_paths=invalid))
        with self.assertRaisesRegex(lifecycle.LifecycleError, "system_paths"):
            lifecycle.validate(dict(manifest, privileged=False))

    def test_root_script_source_commands_in_isolation(self):
        directory, _, _ = self.external()
        options = [str(ROOT_SCRIPT), "--repo", str(self.repo), "--home", str(self.home), "--no-system-effects"]
        for args in (["source", "add", str(directory)], ["source", "list"], ["install", "external-tool"],
                     ["source", "remove", str(directory)], ["uninstall", "external-tool"]):
            result = subprocess.run(options + args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_manifest_traversal_symlinks_and_nonexecutable_plugins_rejected(self):
        source, manifest = self.utility()
        manifest["plugin"]["path"] = "../escape.5s.py"
        (source / "mac-utility.json").write_text(json.dumps(manifest))
        with self.assertRaises(lifecycle.LifecycleError): self.manager.install("memory")
        manifest["plugin"]["path"] = "test.5s.py"
        (source / "mac-utility.json").write_text(json.dumps(manifest))
        (source / "test.5s.py").chmod(0o644)
        with self.assertRaises(lifecycle.LifecycleError): self.manager.install("memory")
        (source / "test.5s.py").chmod(0o755)
        (source / "escape").symlink_to(self.base)
        with self.assertRaisesRegex(lifecycle.LifecycleError, "escapes"):
            self.manager.install("memory")

    def test_app_extensions_register_after_install_and_unregister_on_removal(self):
        source, manifest = self.utility("video-preview", app=True)
        manifest["app"]["extensions"] = ["Sample.appex"]
        (source / "mac-utility.json").write_text(json.dumps(manifest))
        calls = []
        real_run = subprocess.run
        def run(args, *rest, **options):
            if str(args[0]).startswith(("/usr/bin/", "/System/")):
                calls.append([str(a) for a in args])
                return subprocess.CompletedProcess(args, 0)
            return real_run(args, *rest, **options)
        manager = lifecycle.Manager(self.repo, self.home, system_effects=True)
        app = self.home / "Applications/Sample Utility.app"
        appex = str(app / "Contents/PlugIns/Sample.appex")
        with patch.object(lifecycle.Path, "home", return_value=self.home), patch.object(lifecycle.subprocess, "run", run):
            manager.install("video-preview")
            names = [c[0].rsplit("/", 1)[-1] + " " + c[1] for c in calls]
            self.assertIn("lsregister -f", names)
            self.assertIn(["/usr/bin/pluginkit", "-a", appex], calls)
            self.assertIn(["/usr/bin/qlmanage", "-r"], calls)
            self.assertLess(names.index("lsregister -f"), names.index("pluginkit -a"))
            calls.clear()
            manager.uninstall("video-preview")
            self.assertIn(["/usr/bin/pluginkit", "-r", appex], calls)
            self.assertIn(["/usr/bin/qlmanage", "-r"], calls)
            self.assertFalse(app.exists())
        # Without system effects nothing is registered.
        calls.clear()
        with patch.object(lifecycle.subprocess, "run", run):
            self.manager.install("video-preview")
            self.manager.uninstall("video-preview")
        self.assertFalse([c for c in calls if "pluginkit" in c[0] or "qlmanage" in c[0] or "lsregister" in c[0]])

    def test_app_extensions_must_be_appex_names(self):
        source, manifest = self.utility("video-preview", app=True)
        for bad in (["../Escape.appex"], ["Sub/Sample.appex"], ["Sample.app"], "Sample.appex"):
            manifest["app"]["extensions"] = bad
            (source / "mac-utility.json").write_text(json.dumps(manifest))
            with self.assertRaises(lifecycle.LifecycleError):
                self.manager.install("video-preview")

    def test_tampered_receipt_cannot_delete_other_directories(self):
        self.utility()
        self.manager.install("memory")
        receipt = self.manager.receipt("memory")
        foreign = self.base / "unrelated"
        foreign.mkdir()
        (foreign / "keep").write_text("keep")
        receipt["payload"] = str(foreign)
        lifecycle.atomic_json(self.manager.receipts / "memory.json", receipt)
        with self.assertRaises(lifecycle.LifecycleError): self.manager.uninstall("memory")
        self.assertEqual((foreign / "keep").read_text(), "keep")

    def test_legacy_links_migrate_only_with_matching_repository(self):
        source, manifest = self.utility()
        subprocess.run(["/usr/bin/git", "init", str(self.repo)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.manager.plugins.mkdir()
        plugin = self.manager.plugins / "test.5s.py"
        plugin.symlink_to(source / "test.5s.py")
        entry = next(u for u in self.manager.catalog() if u["id"] == "memory")
        self.assertTrue(entry["legacy_plugin"])
        self.manager.install("memory")
        self.assertEqual(self.manager.receipt("memory")["legacy_plugin_target"], str(source / "test.5s.py"))
        self.assertEqual(plugin.resolve(), self.manager.payloads / "memory/test.5s.py")
        self.manager.uninstall("memory")
        foreign_repo = self.base / "foreign"
        foreign_repo.mkdir()
        subprocess.run(["/usr/bin/git", "init", str(foreign_repo)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        foreign = foreign_repo / "memory/test.5s.py"
        foreign.parent.mkdir()
        foreign.write_text("unrelated")
        plugin.symlink_to(foreign)
        with self.assertRaises(lifecycle.LifecycleError): self.manager.install("memory")
        self.assertEqual(plugin.resolve(), foreign)

    def test_missing_dependencies_and_catalog_missing_sources(self):
        source, manifest = self.utility()
        manifest["dependencies"] = [{"name": "img2webp", "paths": [str(self.base / "missing")], "help": "brew install webp"}]
        (source / "mac-utility.json").write_text(json.dumps(manifest))
        entries = self.manager.catalog()
        self.assertEqual(len(entries), len(lifecycle.CATALOG))
        self.assertFalse(next(u for u in entries if u["id"] == "git-settings")["available"])
        self.assertIn("brew install webp", next(u for u in entries if u["id"] == "memory")["missing_dependencies"][0])

    def test_home_relative_dependency_resolves_under_the_managers_home(self):
        source, manifest = self.utility()
        manifest["dependencies"] = [{"name": "uv", "paths": ["~/.local/bin/uv"], "help": "Install uv"}]
        (source / "mac-utility.json").write_text(json.dumps(manifest))
        memory = lambda: next(u for u in self.manager.catalog() if u["id"] == "memory")
        self.assertEqual(memory()["missing_dependencies"], ["uv: Install uv"])
        tool = self.home / ".local/bin/uv"
        tool.parent.mkdir(parents=True)
        tool.write_text("#!/bin/sh\n")
        tool.chmod(0o755)
        self.assertEqual(memory()["missing_dependencies"], [])
        self.assertEqual(self.manager.dependency_path("~/.local/bin/uv"), tool)

    def test_dependency_paths_reject_other_relative_forms(self):
        for bad in ("bin/uv", "./uv", "~", "~/", "~user/bin/uv", "~/../escape/uv", ""):
            self.assertFalse(lifecycle.dependency_path_ok(bad), bad)
        for good in ("/opt/homebrew/bin/uv", "~/.local/bin/uv"):
            self.assertTrue(lifecycle.dependency_path_ok(good), good)
        source, manifest = self.utility()
        manifest["dependencies"] = [{"name": "uv", "paths": ["bin/uv"], "help": "Install uv"}]
        (source / "mac-utility.json").write_text(json.dumps(manifest))
        with self.assertRaisesRegex(lifecycle.LifecycleError, "absolute or start with ~/"):
            self.manager.catalog()

    def test_root_script_selective_and_bulk_operations_in_isolation(self):
        self.utility()
        self.utility("travel-router", privileged=True)
        options = [str(ROOT_SCRIPT), "--repo", str(self.repo), "--home", str(self.home), "--no-system-effects"]
        for args in (["install", "memory"], ["menu", "memory", "hide"], ["--all"], ["--remove"]):
            result = subprocess.run(options + args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNone(self.manager.receipt("memory"))
        self.assertIsNotNone(self.manager.receipt("travel-router"))
        self.assertFalse((self.base / "MUST_NOT_RUN").exists())


class ManagerPackageTests(unittest.TestCase):
    def test_self_installer_requires_receipt_and_preserves_changed_app(self):
        import sys
        sys.path.insert(0, str(BACKEND.parent))
        import package_app
        with tempfile.TemporaryDirectory() as root:
            base = Path(root).resolve()
            manager = lifecycle.Manager(base, base / "home", system_effects=False)
            destination = base / "apps/Mac Utilities.app"
            destination.mkdir(parents=True)
            (destination / "foreign").write_text("keep")
            staged = base / "stage/Mac Utilities.app"
            staged.mkdir(parents=True)
            (staged / "Contents").mkdir()
            (staged / "Contents/executable").write_text("manager")
            with self.assertRaises(lifecycle.LifecycleError): package_app.publish(manager, staged, destination)
            self.assertEqual((destination / "foreign").read_text(), "keep")
            shutil = __import__("shutil")
            shutil.rmtree(destination)
            package_app.publish(manager, staged, destination)
            (destination / "extra").write_text("user file")
            with self.assertRaises(lifecycle.LifecycleError): package_app.uninstall(manager, destination)
            (destination / "extra").unlink()
            package_app.uninstall(manager, destination)
            self.assertFalse(destination.exists())

if __name__ == "__main__":
    unittest.main()
