"""The export checker must distinguish modules from values they construct."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import luacheck


class ModuleAliases(unittest.TestCase):
    def check_source(self, source):
        return luacheck.cross_module(source, luacheck.strip(source, 'fixture.lua'),
                                     'fixture.lua', {'factory': {'new'}})

    def test_factory_result_is_not_the_module(self):
        self.assertEqual([], self.check_source(
            'local instance = require("factory").new()\ninstance:record()'))

    def test_missing_factory_member_is_still_reported(self):
        failures = self.check_source('local instance = require("factory").typo()\ninstance:record()')
        self.assertEqual(1, len(failures))
        self.assertIn('typo', failures[0])

    def test_direct_alias_remains_checked(self):
        self.assertEqual([], self.check_source('local module = require("factory")\nmodule.new()'))
        self.assertEqual(1, len(self.check_source('local module = require("factory")\nmodule.typo()')))

    def test_multiline_postfix(self):
        self.assertEqual([], self.check_source('local instance = require("factory")\n  .new()\ninstance:record()'))

    def test_comment_does_not_create_alias(self):
        self.assertEqual([], self.check_source('-- local instance = require("factory")\ninstance:record()'))

    def test_dynamic_index_result_not_module(self):
        self.assertEqual([], self.check_source('local instance = require("factory")[key]()\ninstance:record()'))


if __name__ == '__main__':
    unittest.main()
