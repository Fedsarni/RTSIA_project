"""SemIf decision node: one forward pass, option probabilities, no decoding."""
import json
import threading
import time

import rclpy
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from std_msgs.msg import String

from .common import SENSOR_QOS
from .latest_queue import LatestQueue
from .semif_adapter import MODEL, REVISION, SemifScorer


class SemifNode(Node):
    def __init__(self):
        super().__init__('semif_node')
        self.declare_parameter('system', 'semif-qwen4b')
        self.declare_parameter('model', MODEL)
        self.declare_parameter('revision', REVISION)
        self.declare_parameter('mode', 'direct')          # direct | serial
        self.declare_parameter('dtype', 'bfloat16')
        self.declare_parameter('warmup', 3)
        p = lambda name: self.get_parameter(name).value
        self.system = p('system')
        self.mode = p('mode')
        self.get_logger().info(f"Loading SemIf ({p('model')}, mode={self.mode})...")
        self.scorer = SemifScorer(model=p('model'), revision=p('revision'), mode=self.mode,
                                  dtype=p('dtype'), warmup=p('warmup'))
        self.get_logger().info('SemIf ready (warm-up done).')
        self.q = LatestQueue()
        self.pub = self.create_publisher(String, 'decision/semif', 10)
        self.create_subscription(String, 'sensors', self.on_sensor, SENSOR_QOS)
        threading.Thread(target=self.worker, daemon=True).start()

    def on_sensor(self, msg):
        self.q.put(json.loads(msg.data))

    def worker(self):
        while rclpy.ok():
            m = self.q.get()
            if m is None:
                continue
            t_in = time.monotonic_ns()
            try:
                probs, info = self.scorer.score_detailed(m["row"])
            except Exception as e:  # keep the node alive; the gap shows up in the log
                self.get_logger().warning(f"seq {m['seq']}: SemIf scoring failed: {e}")
                continue
            t_out = time.monotonic_ns()
            choice = max(probs, key=probs.get)
            self.pub.publish(String(data=json.dumps({
                "system": self.system,
                "seq": m["seq"],
                "t_gen_ns": m["t_gen_ns"],
                "t_in_ns": t_in,
                "t_out_ns": t_out,
                "action": choice,
                "expected": m["expected"],
                "confidence": probs[choice],
                "n_prompt_tokens": info["n_prompt_tokens"],
                # SemIf's single forward pass is logged as prefill; there is no decode.
                "prefill_ms": info["forward_ms"],
                "decode_ms": 0.0,
                "n_output_tokens": 0,
                "prompt_cache": self.mode == "serial",
                "dropped": self.q.dropped,
            })))


def main():
    rclpy.init()
    try:
        rclpy.spin(SemifNode())
    except (KeyboardInterrupt, ExternalShutdownException):
        pass  # normal stop (Ctrl+C or SIGTERM from run_experiment.sh)


if __name__ == '__main__':
    main()
