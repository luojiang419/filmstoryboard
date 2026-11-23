import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import profile_scenario_runner as runner  # noqa: E402


class ProfileScenarioRunnerTest(unittest.TestCase):
    def test_all_scenarios_are_read_only_pointer_actions(self):
        self.assertGreaterEqual(len(runner.SCENARIOS), 4)
        for name, (_, actions) in runner.SCENARIOS.items():
            self.assertTrue(name)
            for action in actions:
                self.assertIn(action[0], {'click', 'scroll', 'sleep'})
                self.assertNotIn(action[0], {'type', 'delete', 'write'})

    def test_expected_pages_have_navigation_and_measurement_actions(self):
        for name, (_, actions) in runner.SCENARIOS.items():
            self.assertEqual(actions[0][0], 'click')
            self.assertTrue(any(action[0] in {'click', 'scroll'} for action in actions[1:]))


if __name__ == '__main__':
    unittest.main()
