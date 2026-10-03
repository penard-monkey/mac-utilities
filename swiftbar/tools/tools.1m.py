#!/usr/bin/python3
# <swiftbar.title>Tools</swiftbar.title>
# <swiftbar.desc>Launch your Mac utilities and manage installed tools.</swiftbar.desc>
# <swiftbar.version>2.0</swiftbar.version>
import json
import os
import subprocess
import sys
from pathlib import Path

CONFIG_DIR = Path.home() / '.config/mac-utilities'
CONFIG = CONFIG_DIR / 'tools.json'
MANAGED = CONFIG_DIR / 'installed-tools.json'
MANAGER = Path.home() / 'Applications/Mac Utilities.app'
DEFAULTS = [{'name': 'GIF Stickers', 'app': '~/Applications/GIF Stickers.app'}]


def read_entries(path, default):
    if not path.exists():
        return default
    data = json.loads(path.read_text())
    if not isinstance(data, list):
        raise ValueError('Expected a list of tools')
    for item in data:
        if not isinstance(item, dict) or not all(isinstance(item.get(k), str) and item[k].strip() for k in ('name', 'app')):
            raise ValueError('Each tool needs a name and an app path')
        if any(c in item['app'] for c in '\n\r\0'):
            raise ValueError('App paths must be on one line')
        if not Path(os.path.expanduser(item['app'])).is_absolute():
            raise ValueError('Use an absolute app path or ~/Applications/...')
        if 'visible' in item and not isinstance(item['visible'], bool):
            raise ValueError('Visibility must be true or false')
    return data


def app_path(item):
    return os.path.normpath(os.path.expanduser(item['app']))


def entries():
    result, errors, seen = [], [], set()
    # Managed visibility wins over a duplicate custom entry. An empty managed
    # catalog also suppresses legacy defaults after uninstalling the last app.
    for path, default in ((MANAGED, []), (CONFIG, [] if MANAGED.exists() else DEFAULTS)):
        try:
            for item in read_entries(path, default):
                app = app_path(item)
                if app in seen:
                    continue
                seen.add(app)
                if item.get('visible', True):
                    result.append(item)
        except (OSError, ValueError) as error:
            errors.append((path.name, str(error)))
    return result, errors


def title(value):
    return ''.join(' ' if ord(c) < 32 or ord(c) == 127 else c for c in value).replace('|', '／').lstrip('-')


def quoted(value):
    return json.dumps(str(value), ensure_ascii=False)


def installed(path):
    return path.is_dir() and path.suffix.lower() == '.app'


def open_app(path):
    if not installed(path):
        raise ValueError('App is not installed: {}'.format(path.name))
    subprocess.run(['/usr/bin/open', str(path)], check=True)


def main():
    if len(sys.argv) > 1:
        if sys.argv[1:] == ['--edit']:
            CONFIG.parent.mkdir(parents=True, exist_ok=True)
            if not CONFIG.exists():
                CONFIG.write_text('[]\n')
            subprocess.run(['/usr/bin/open', '-t', str(CONFIG)], check=True)
        elif sys.argv[1:] == ['--manage']:
            open_app(MANAGER)
        elif sys.argv[1] == '--launch' and len(sys.argv) == 3:
            # Recheck membership using the displayed app path, not a list index
            # that could change between rendering and clicking the menu.
            tools, _ = entries()
            if sys.argv[2] not in {app_path(item) for item in tools}:
                raise ValueError('Tool is no longer enabled')
            open_app(Path(sys.argv[2]))
        else:
            raise ValueError('Unknown action')
        return
    print('Tools | sfimage=shippingbox dropdown=false')
    print('---')
    script = Path(__file__).resolve()
    tools, errors = entries()
    for item in tools:
        app = Path(app_path(item))
        label = title(item['name'])
        if installed(app):
            print('{} | bash=/usr/bin/python3 param1={} param2=--launch param3={} terminal=false'.format(label, quoted(script), quoted(app)))
        else:
            print('{} — not installed | color=gray'.format(label))
    if not tools and not errors:
        print('No tools enabled | color=gray')
    for filename, error in errors:
        print('Cannot read {} | color=red'.format(title(filename)))
        print('{} | color=gray'.format(title(error)))
    print('---')
    if installed(MANAGER):
        print('Manage Utilities… | bash=/usr/bin/python3 param1={} param2=--manage terminal=false'.format(quoted(script)))
    else:
        print('Mac Utilities — not installed | color=gray')
    print('Edit Custom Tools… | bash=/usr/bin/python3 param1={} param2=--edit terminal=false refresh=true'.format(quoted(script)))
    print('Refresh | refresh=true')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
