#!/usr/bin/python3
"""Receipt-protected installation/removal of the manager bundle itself."""
import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from lifecycle import Manager, LifecycleError, atomic_json, digest

def publish(manager, source, destination):
    receipt = manager.root / "state/manager-app.json"
    destination = Path(destination).absolute()
    source = Path(source)
    previous = json.loads(receipt.read_text()) if receipt.exists() else None
    if destination.exists() or destination.is_symlink():
        if not previous or previous.get("app") != str(destination) or digest(destination) != previous.get("app_digest"):
            raise LifecycleError("Refusing to replace unowned or modified manager app: " + str(destination))
    if previous and previous.get("app") != str(destination) and Path(previous["app"]).exists():
        raise LifecycleError("Manager is already owned at " + previous["app"] + "; uninstall it before changing destinations")
    record = {"schema": 1, "id": "utilities-manager", "app": str(destination), "app_digest": digest(source)}
    backup = source.parent / "previous-manager.app"
    had_previous = destination.exists()
    moved_previous = False
    published = False
    try:
        if had_previous:
            os.replace(str(destination), str(backup))
            moved_previous = True
        os.replace(str(source), str(destination))
        published = True
        atomic_json(receipt, record)
    except Exception:
        if published and destination.exists():
            shutil.rmtree(str(destination))
        if moved_previous and backup.exists():
            os.replace(str(backup), str(destination))
        raise
    if backup.exists():
        shutil.rmtree(str(backup))

def uninstall(manager, destination):
    receipt = manager.root / "state/manager-app.json"
    destination = Path(destination).absolute()
    if not receipt.exists():
        raise LifecycleError("No ownership receipt; manager app left alone")
    record = json.loads(receipt.read_text())
    if record.get("schema") != 1 or record.get("id") != "utilities-manager" or record.get("app") != str(destination) or digest(destination) != record.get("app_digest"):
        raise LifecycleError("Manager app is unowned or modified; left alone")
    # Stage beside the application so rename is atomic even on another volume.
    with tempfile.TemporaryDirectory(prefix=".remove-manager-", dir=str(destination.parent)) as work:
        backup = Path(work) / destination.name
        os.replace(str(destination), str(backup))
        try:
            receipt.unlink()
        except Exception:
            os.replace(str(backup), str(destination))
            raise

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", default=str(Path.home()))
    parser.add_argument("action", choices=("install", "uninstall"))
    parser.add_argument("destination")
    parser.add_argument("source", nargs="?")
    args = parser.parse_args()
    manager = Manager(Path(__file__).resolve().parents[2], args.home, system_effects=False)
    try:
        with manager.lock():
            if args.action == "install":
                if not args.source: raise LifecycleError("Install requires a staged bundle")
                publish(manager, args.source, args.destination)
            else:
                uninstall(manager, args.destination)
        print(args.action + "ed " + args.destination)
        return 0
    except (OSError, ValueError, LifecycleError) as error:
        print(str(error), file=sys.stderr)
        return 1

if __name__ == "__main__": sys.exit(main())
