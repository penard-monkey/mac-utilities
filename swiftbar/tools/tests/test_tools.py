import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('tools_plugin', Path(__file__).parents[1] / 'tools.1m.py')
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)


class ToolsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.patcher = patch.multiple(tools, CONFIG=root / 'tools.json', MANAGED=root / 'installed-tools.json')
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def write(self, path, data):
        path.write_text(json.dumps(data))

    def test_managed_visibility_wins_and_custom_apps_survive(self):
        self.write(tools.MANAGED, [{'name': 'Git', 'app': '/Applications/Git.app', 'visible': False}])
        self.write(tools.CONFIG, [{'name': 'Duplicate', 'app': '/Applications/Git.app'}, {'name': 'Custom', 'app': '/Applications/Custom.app'}])
        entries, errors = tools.entries()
        self.assertEqual([item['name'] for item in entries], ['Custom'])
        self.assertFalse(errors)

    def test_broken_custom_file_does_not_hide_managed_apps(self):
        self.write(tools.MANAGED, [{'name': 'Git', 'app': '/Applications/Git.app'}])
        tools.CONFIG.write_text('{broken')
        entries, errors = tools.entries()
        self.assertEqual(entries[0]['name'], 'Git')
        self.assertEqual(errors[0][0], 'tools.json')

    def test_empty_catalog_does_not_resurrect_default(self):
        self.write(tools.MANAGED, [])
        self.assertEqual(tools.entries(), ([], []))

    def test_rejects_control_characters_in_path(self):
        self.write(tools.CONFIG, [{'name': 'Bad', 'app': '/Applications/Bad\n.app'}])
        entries, errors = tools.entries()
        self.assertFalse(entries)
        self.assertTrue(errors)

    def test_launch_is_argument_array_and_uses_stable_path(self):
        app = Path(self.temp.name) / 'A $(touch nope).app'
        app.mkdir()
        self.write(tools.CONFIG, [{'name': 'App', 'app': str(app)}])
        with patch.object(tools.sys, 'argv', ['plugin', '--launch', str(app)]), patch.object(tools.subprocess, 'run') as run:
            tools.main()
        run.assert_called_once_with(['/usr/bin/open', str(app)], check=True)
        self.write(tools.CONFIG, [])
        with patch.object(tools.sys, 'argv', ['plugin', '--launch', str(app)]):
            with self.assertRaises(ValueError):
                tools.main()


if __name__ == '__main__':
    unittest.main()
