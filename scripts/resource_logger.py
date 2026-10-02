#!/usr/bin/env python3
"""System resource logger for Jetson (requires jetson-stats: `sudo pip3 install jetson-stats`).

Samples every jtop metric (CPU/GPU load, RAM, swap, power rails, temperatures)
and writes them to CSV together with a CLOCK_MONOTONIC timestamp, the same
clock used by the ROS nodes, so resources can be aligned with each decision.

Why the interval check: the jtop service has ONE update interval, shared by all
clients (e.g. the jtop UI open in another terminal). If the service updates more
slowly than the interval we request, jtop's ok() times out after 3x our interval
and the loop ends after the first sample. So we read the service interval and,
if it is slower, reconnect using it.

Usage:
    python3 resource_logger.py --out resources.csv --interval 0.1
Stops cleanly on Ctrl+C or SIGTERM (as sent by run_experiment.sh).
"""
import argparse
import csv
import signal
import sys
import time

from jtop import jtop, JtopException

STOP = False


def _stop(*_):
    global STOP
    STOP = True


def log(msg):
    print(f'[resource_logger] {msg}', flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='resources.csv')
    ap.add_argument('--interval', type=float, default=0.1, help='requested seconds between samples')
    args = ap.parse_args()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    interval = args.interval
    rows = 0
    writer = None
    with open(args.out, 'w', newline='') as fh:
        while not STOP:
            try:
                with jtop(interval=interval) as jetson:
                    service = float(jetson.interval)
                    if service > interval * 1.05:
                        log(f'jtop service updates every {service:g} s (requested {interval:g} s): '
                            f'reconnecting at {service:g} s')
                        interval = service
                        continue
                    log(f'sampling every {service:g} s -> {args.out}')
                    while not STOP and jetson.ok():
                        row = {'t_mono_ns': time.monotonic_ns()}
                        row.update({k: str(v) for k, v in jetson.stats.items()})
                        if writer is None:
                            writer = csv.DictWriter(fh, fieldnames=list(row.keys()),
                                                    extrasaction='ignore', restval='')
                            writer.writeheader()
                        writer.writerow(row)
                        fh.flush()
                        rows += 1
                if not STOP:
                    log('jtop stream interrupted, reconnecting')
                    time.sleep(0.5)
            except JtopException as error:
                log(f'jtop error: {error}; retrying in 1 s')
                time.sleep(1)
    log(f'stopped, {rows} samples written')
    return 0


if __name__ == '__main__':
    sys.exit(main())
