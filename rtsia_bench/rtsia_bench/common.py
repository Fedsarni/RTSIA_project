"""Shared QoS profile and decision task definition.

Every decision system (SemIf and the generative LLMs) receives exactly the
same state, question and options, so their outputs are directly comparable.
"""
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy

# Real-time sensor stream: only the most recent sample matters.
SENSOR_QOS = QoSProfile(
    reliability=ReliabilityPolicy.BEST_EFFORT,
    history=HistoryPolicy.KEEP_LAST,
    depth=1,
)

# The decision rules are part of the task: they are stated in the question and
# option descriptions, so every model decides with the same information, and
# they match sensor_sim.expected_action() exactly. `speed_m_s` is in the state
# but not in the rules (a deliberate distractor).
QUESTION = ("Which action should the robot take right now? "
            "Apply exactly the rules stated in the options.")

OPTIONS = [
    {"id": "proceed",
     "description": ("Keep moving at the current speed: the obstacle is at least 1.5 m away "
                     "and the motor temperature is at most 75 degrees C.")},
    {"id": "slow_down",
     "description": ("Reduce speed: no stop condition holds, and the obstacle is closer than 1.5 m "
                     "or the motor temperature is above 75 degrees C.")},
    {"id": "stop",
     "description": ("Stop immediately: the obstacle is closer than 0.5 m, "
                     "or the motor temperature is above 90 degrees C.")},
]
