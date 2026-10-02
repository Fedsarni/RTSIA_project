"""Simulated sensor stream.

Publishes a decision row (state + question + options) at a configurable rate,
with a fixed seed so every run receives the same sequence. The expected action,
computed from known rules, travels with the message as ground truth but is
never shown to the models.

The run ends by itself when `duration_s` or `max_samples` is reached
(0 = no limit): the node then exits, so a script can wait for it.
"""
import json
import random
import time

import rclpy
from rcl_interfaces.msg import ParameterDescriptor
from rclpy.node import Node
from std_msgs.msg import String

from .common import SENSOR_QOS, QUESTION, OPTIONS


def expected_action(state):
    """Ground truth. Must stay identical to the rules in common.OPTIONS."""
    if state["obstacle_distance_m"] < 0.5 or state["motor_temperature_c"] > 90:
        return "stop"
    if state["obstacle_distance_m"] < 1.5 or state["motor_temperature_c"] > 75:
        return "slow_down"
    return "proceed"


class SensorSim(Node):
    def __init__(self):
        super().__init__('sensor_sim')
        any_type = ParameterDescriptor(dynamic_typing=True)  # accept rate_hz:=2 as well as 2.0
        self.declare_parameter('rate_hz', 2.0, any_type)
        self.declare_parameter('seed', 42)
        self.declare_parameter('duration_s', 0.0, any_type)
        self.declare_parameter('max_samples', 0)
        random.seed(self.get_parameter('seed').value)
        self.duration_s = float(self.get_parameter('duration_s').value)
        self.max_samples = int(self.get_parameter('max_samples').value)
        self.pub = self.create_publisher(String, 'sensors', SENSOR_QOS)
        self.seq = 0
        self.t_start = None
        self.done = False
        rate = float(self.get_parameter('rate_hz').value)
        self.timer = self.create_timer(1.0 / rate, self.tick)
        limits = []
        if self.duration_s > 0:
            limits.append(f'{self.duration_s:g} s')
        if self.max_samples > 0:
            limits.append(f'{self.max_samples} samples')
        self.get_logger().info(f"Publishing at {rate:g} Hz, limit: {' / '.join(limits) or 'none'}")

    def limit_reached(self):
        if self.max_samples > 0 and self.seq >= self.max_samples:
            return True
        if self.duration_s > 0 and self.t_start is not None:
            return time.monotonic() - self.t_start >= self.duration_s
        return False

    def tick(self):
        if self.t_start is None:
            self.t_start = time.monotonic()
        if self.limit_reached():
            self.timer.cancel()
            self.done = True
            self.get_logger().info(f'Done: published {self.seq} samples.')
            return
        state = {
            "obstacle_distance_m": round(random.uniform(0.2, 5.0), 2),
            "motor_temperature_c": round(random.gauss(65, 12), 1),
            "speed_m_s": round(random.uniform(0.0, 2.0), 2),
        }
        msg = {
            "seq": self.seq,
            "t_gen_ns": time.monotonic_ns(),
            "expected": expected_action(state),
            "row": {"id": f"s{self.seq}", "state": state,
                    "question": QUESTION, "options": OPTIONS},
        }
        self.pub.publish(String(data=json.dumps(msg)))
        self.seq += 1


def main():
    rclpy.init()
    node = SensorSim()
    try:
        while rclpy.ok() and not node.done:
            rclpy.spin_once(node, timeout_sec=0.1)
    except KeyboardInterrupt:
        pass
    node.destroy_node()
    if rclpy.ok():
        rclpy.shutdown()


if __name__ == '__main__':
    main()
