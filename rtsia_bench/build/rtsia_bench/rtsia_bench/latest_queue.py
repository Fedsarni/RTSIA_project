"""Single-slot queue that always keeps the most recent item.

If a new sample arrives while the model is still busy, the older pending
sample is dropped and counted. The drop count is itself a responsiveness
metric, and using the same policy for every system keeps the comparison fair.
"""
import queue


class LatestQueue:
    def __init__(self):
        self._q = queue.Queue(maxsize=1)
        self.dropped = 0

    def put(self, item):
        try:
            self._q.put_nowait(item)
        except queue.Full:
            try:
                self._q.get_nowait()
                self.dropped += 1
            except queue.Empty:
                pass
            self._q.put_nowait(item)

    def get(self, timeout=0.5):
        """Return the next item, or None after `timeout` seconds."""
        try:
            return self._q.get(timeout=timeout)
        except queue.Empty:
            return None
