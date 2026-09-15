import unittest
from compare import action_key, compare, probabilities


class ComparisonTests(unittest.TestCase):
    def test_different_bet_amounts_do_not_match(self):
        self.assertNotEqual(action_key('bet 10',0,(0,0),100,'zolver'),action_key('BET 20',0,(0,0),100,'texas'))

    def test_raise_increment_matches_total_commitment(self):
        self.assertEqual(action_key('raise 30',1,(15,0),100,'zolver'),action_key('RAISE 45',1,(15,0),100,'texas'))
        self.assertEqual(action_key('all-in',1,(15,0),100,'zolver'),action_key('RAISE 100',1,(15,0),100,'texas'))

    def test_missing_coverage_fails(self):
        n={'player':0,'keys':{('check',0)},'strat':{'AsKs':{('check',0):1}}}
        self.assertFalse(compare({():n,('extra',):n},{():n},.05)['passed'])

    def test_probability_validation(self):
        with self.assertRaises(ValueError): probabilities([('AsKs',[float('nan')])],[('check',0)])

    def test_frequency_gate_fails(self):
        keys=[('check',0),('bet_to',10)]
        def node(p): return {'player':0,'keys':set(keys),'strat':probabilities([('AsKs',p)],keys)}
        self.assertFalse(compare({():node([1,0])},{():node([0,1])},.05)['passed'])


if __name__ == '__main__': unittest.main()
