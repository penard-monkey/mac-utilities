#!/usr/bin/python3
"""Fail closed when a release tag, VERSION, or bootstrap script disagree."""
import argparse
import json
from pathlib import Path
import re


def repo_slug(root):
    matches = re.findall(r'^REPO="([^"]+)"$', (root/'install.sh').read_text(), re.M)
    if len(matches) != 1 or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', matches[0]):
        raise ValueError('install.sh must declare exactly one repository slug')
    return matches[0]


def check(root, tag=None, repository=None):
    slug = repo_slug(root)
    if repository is not None and repository != slug:
        raise ValueError('Configure install.sh REPO for the repository publishing these artifacts')
    version = (root / 'VERSION').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('VERSION must be X.Y.Z')
    matches = re.findall(r'^SCRIPT_VERSION="(v[^"]+)"$', (root / 'install.sh').read_text(), re.M)
    if matches != ['v' + version] or (tag is not None and tag != 'v' + version):
        raise ValueError('tag, VERSION and install.sh SCRIPT_VERSION must agree')
    if not re.search(r'^## \['+re.escape(version)+r'\]$', (root/'CHANGELOG.md').read_text(), re.M):
        raise ValueError('CHANGELOG.md requires notes for VERSION')
    if tag is not None and not (root/'LICENSE').is_file():
        # The private artifact proof predates the public cut-over; a tagged
        # publication must include the license supplied by that cut-over.
        raise ValueError('Add the approved LICENSE before tagging a public release')
    for path in list(root.glob('*/mac-utility.json')) + list(root.glob('swiftbar/*/mac-utility.json')):
        if not re.fullmatch(r'\d+\.\d+\.\d+', json.loads(path.read_text()).get('version', '')):
            raise ValueError('Invalid per-utility version: ' + str(path))
    return version


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--tag')
    parser.add_argument('--repository')
    args = parser.parse_args()
    print(check(args.repo, args.tag, args.repository))
