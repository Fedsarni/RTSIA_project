"""Generative decision node backed by llama-server (llama.cpp).

One node type serves both generative arms:
  - Gemma 4 31B Q8  (default, port 8080, topic decision/gemma)
  - Qwen3.5-4B      (control arm, port 8081, topic decision/qwen)

The prompt contains exactly the same state, question and options SemIf
receives. A JSON schema with an enum forces the model to answer with one of
the option ids, so the output is short and parseable.
"""
import json
import threading
import time

import requests
import rclpy
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from std_msgs.msg import String

from .common import SENSOR_QOS
from .latest_queue import LatestQueue

SYSTEM_PROMPT = ("You are the decision module of a mobile robot. "
                 "Reply only with the requested JSON.")


def build_prompt(row):
    """Fixed part first, sensor state last.

    llama-server's prompt cache reuses the longest unchanged prefix, so with the
    question and options first only the state tokens need a new prefill
    (effective when cache_prompt is true).
    """
    options = "\n".join(f"- {o['id']}: {o['description']}" for o in row["options"])
    return (f"Question: {row['question']}\n"
            f"Options:\n{options}\n"
            f"Sensor state: {json.dumps(row['state'])}")


class LlmGenNode(Node):
    def __init__(self):
        super().__init__('llm_gen_node')
        self.declare_parameter('url', 'http://127.0.0.1:8080/v1/chat/completions')
        self.declare_parameter('system', 'gen-gemma31b')
        self.declare_parameter('topic', 'decision/gemma')
        self.declare_parameter('cache_prompt', True)
        self.declare_parameter('max_tokens', 32)
        self.url = self.get_parameter('url').value
        self.system = self.get_parameter('system').value
        self.cache_prompt = self.get_parameter('cache_prompt').value
        self.max_tokens = self.get_parameter('max_tokens').value
        self.q = LatestQueue()
        self.pub = self.create_publisher(String, self.get_parameter('topic').value, 10)
        self.create_subscription(String, 'sensors', self.on_sensor, SENSOR_QOS)
        threading.Thread(target=self.worker, daemon=True).start()

    def on_sensor(self, msg):
        self.q.put(json.loads(msg.data))

    def worker(self):
        session = requests.Session()
        while rclpy.ok():
            m = self.q.get()
            if m is None:
                continue
            row = m["row"]
            schema = {
                "type": "object",
                "required": ["action"],
                "properties": {"action": {"type": "string",
                                          "enum": [o["id"] for o in row["options"]]}},
            }
            t_in = time.monotonic_ns()
            try:
                r = session.post(self.url, timeout=300, json={
                    "messages": [{"role": "system", "content": SYSTEM_PROMPT},
                                 {"role": "user", "content": build_prompt(row)}],
                    "response_format": {"type": "json_schema", "json_schema": {"schema": schema}},
                    "max_tokens": self.max_tokens,
                    "temperature": 0,
                    "cache_prompt": self.cache_prompt,
                }).json()
                action = json.loads(r["choices"][0]["message"]["content"])["action"]
            except Exception as e:  # keep the node alive; the gap shows up in the log
                self.get_logger().warning(f"seq {m['seq']}: request failed: {e}")
                continue
            t_out = time.monotonic_ns()
            tm = r.get("timings", {})  # llama.cpp extension: prefill/decode split
            self.pub.publish(String(data=json.dumps({
                "system": self.system,
                "seq": m["seq"],
                "t_gen_ns": m["t_gen_ns"],
                "t_in_ns": t_in,
                "t_out_ns": t_out,
                "action": action,
                "expected": m["expected"],
                "n_prompt_tokens": tm.get("prompt_n"),
                "prefill_ms": tm.get("prompt_ms"),
                "n_output_tokens": tm.get("predicted_n"),
                "decode_ms": tm.get("predicted_ms"),
                "prompt_cache": self.cache_prompt,
                "dropped": self.q.dropped,
            })))


def main():
    rclpy.init()
    try:
        rclpy.spin(LlmGenNode())
    except (KeyboardInterrupt, ExternalShutdownException):
        pass  # normal stop (Ctrl+C or SIGTERM from run_experiment.sh)


if __name__ == '__main__':
    main()
