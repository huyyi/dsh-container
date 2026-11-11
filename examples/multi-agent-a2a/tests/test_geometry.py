import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('geometry', ROOT / 'agent-b/check_geometry.py')
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


class GeometryTests(unittest.TestCase):
    def setUp(self):
        self.data = g.load_warehouse(ROOT / 'agent-b/AGENTS.md')

    def test_deployment_and_report(self):
        self.assertEqual(len(self.data['sensors']), 6)
        plan = {'warehouseId': self.data['warehouseId'], 'rounds': [
            {'headings': {s['id']: s['heading'] for s in self.data['sensors']}}]}
        result = g.check(self.data, plan, (8.5, 5.5), 3)
        self.assertEqual(result['walkableCells'], 116)
        self.assertGreater(result['priorityCells'], 0)
        self.assertLessEqual(result['summary']['priorityEverDualSameRound'], result['priorityCells'])

    def test_sector_range_availability_and_wrap(self):
        s = {'position': [0, 0], 'fov': 90, 'range': 2, 'available': True}
        self.assertTrue(g.sees(s, 360, (1, 1), []))
        self.assertFalse(g.sees(s, 0, (0, 1), []))
        self.assertFalse(g.sees(s, 0, (3, 0), []))
        s['available'] = False
        self.assertFalse(g.sees(s, 0, (1, 0), []))

    def test_occlusion_and_mount_contact(self):
        self.assertTrue(g.intersects_box((0, 0), (3, 3), (1, 1, 2, 2)))
        self.assertTrue(g.intersects_box((0, 2), (2, 0), (1, 1, 2, 2)))
        self.assertFalse(g.intersects_box((1, 3), (2, 3), (0, 2, 1, 3)))

    def test_mechanical_limits(self):
        sensor = self.data['sensors'][0]
        self.assertEqual(g.legal_heading(sensor, 350, 0), -10)
        with self.assertRaises(ValueError):
            g.legal_heading(sensor, 180, 0)

    def test_single_observations_in_different_rounds_are_not_dual(self):
        data = {'warehouseId': 'test', 'matrix': ['#####', '#...#', '#...#', '#...#', '#####'],
                'sensors': [dict(id='W', position=[1, 2.5], heading=0, fov=30, range=5, rotation=[-90, 90], available=True),
                            dict(id='E', position=[4, 2.5], heading=180, fov=30, range=5, rotation=[90, 270], available=True)]}
        plan = {'warehouseId': 'test', 'rounds': [{'headings': {'W': 0, 'E': 90}}, {'headings': {'W': 90, 'E': 180}}]}
        report = g.check(data, plan, (2.5, 2.5), 0)
        self.assertEqual(report['summary']['priorityEverCovered'], 1)
        self.assertEqual(report['summary']['priorityEverDualSameRound'], 0)


if __name__ == '__main__':
    unittest.main()
