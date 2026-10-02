"""Decision logger: one CSV row per decision, tidy format for JMP.

Experimental factors are passed as ROS parameters, so every row carries the
full experimental condition it was measured under.
"""
import csv
import json
import os

import rclpy
from rclpy.executors import ExternalShutdownException
from rcl_interfaces.msg import ParameterDescriptor
from rclpy.node import Node
from std_msgs.msg import String

FACTORS = ['run_id', 'freq_hz', 'interference', 'interference_level',
           'isolation', 'colocation', 'repetition']
FIELDS = (['system'] + FACTORS +
          ['seq', 'action', 'expected', 'correct', 'confidence',
           'e2e_ms', 'queue_ms', 'infer_ms', 'prefill_ms', 'decode_ms',
           'n_prompt_tokens', 'n_output_tokens', 'prompt_cache', 'dropped'])
TOPICS = ('decision/semif', 'decision/gemma', 'decision/qwen')


class DecisionLogger(Node):
    def __init__(self):
        super().__init__('decision_logger')
        self.declare_parameter('file', 'runs.csv')
        # dynamic_typing: factors may be passed as numbers (freq_hz:=2) or strings.
        for f in FACTORS:
            self.declare_parameter(f, '', ParameterDescriptor(dynamic_typing=True))
        path = self.get_parameter('file').value
        is_new = not os.path.exists(path) or os.path.getsize(path) == 0
        if not is_new:
            with open(path, newline='') as fh:
                header = next(csv.reader(fh), [])
            if header != FIELDS:
                raise RuntimeError(
                    f'{path} has different columns (older package version?). '
                    'Use a new file name.')
        self.fh = open(path, 'a', newline='')
        self.writer = csv.DictWriter(self.fh, fieldnames=FIELDS,
                                     extrasaction='ignore', restval='')
        if is_new:
            self.writer.writeheader()
        for t in TOPICS:
            self.create_subscription(String, t, self.on_decision, 10)
        self.get_logger().info(f'Logging to {os.path.abspath(path)}')

    def on_decision(self, msg):
        d = json.loads(msg.data)
        for f in FACTORS:
            d[f] = str(self.get_parameter(f).value)
        d['correct'] = d['action'] == d['expected']
        d['e2e_ms'] = (d['t_out_ns'] - d['t_gen_ns']) / 1e6
        d['queue_ms'] = (d['t_in_ns'] - d['t_gen_ns']) / 1e6
        d['infer_ms'] = (d['t_out_ns'] - d['t_in_ns']) / 1e6
        self.writer.writerow(d)
        self.fh.flush()


def main():
    rclpy.init()
    try:
        rclpy.spin(DecisionLogger())
    except (KeyboardInterrupt, ExternalShutdownException):
        pass  # normal stop (Ctrl+C or SIGTERM from run_experiment.sh)


if __name__ == '__main__':
    main()
