#!/usr/bin/env python3
"""
failover_timer.py — measures root-failover recovery time (POC-BRIEF.md §3/§7
step 7) by watching a firmware log stream for the surviving node reporting
it became root, and timing from a manual "power cut now" mark.

The exact ESP_LOG line node/board firmware prints for HEARTBEAT/TOPOLOGY is
not fixed by this tool — pocs/node's logging format is whatever that
firmware ends up emitting. --pattern below has a best-guess default; once
you see real log output, pass your own --pattern to match it.

Default --pattern expects a named group `layer` (the reported LAYER field)
and optionally `mac` (the reporting device), e.g. a line like:
    I (12345) siot_node: HEARTBEAT src=AA:BB:CC:DD:EE:02 layer=1 rssi=-60

NOTE on "root layer": docs/safr/protocol-safr-v3.md §7.3 defines the SAFR
HEARTBEAT LAYER field with root = 0. POC-BRIEF.md §7 step 3/7, describing
this same POC, instead talks about the root sitting at Mesh-Lite "layer 1"
(the other AC device at layer 2) — Mesh-Lite's own internal level numbering
starts at 1, which may be what the firmware actually logs even if it maps to
SAFR LAYER=0 on the wire. This tool does not resolve that discrepancy for
you: --root-layer defaults to 0 (the wire-protocol convention) — pass
--root-layer 1 if your node firmware's log line prints the raw Mesh-Lite
level instead.

Usage:
    idf.py monitor | python3 failover_timer.py --dead-node AA:BB:CC:DD:EE:01
    python3 failover_timer.py --source serial.log --repeat 5
"""
import argparse
import re
import statistics
import sys
import time

DEFAULT_PATTERN = (
    r"HEARTBEAT.*?(?:src=|mac=)?(?P<mac>[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})"
    r".*?layer[=: ]+(?P<layer>\d+)"
)


def follow_lines(source: str | None):
    """Yields lines as they arrive: from a file (tailed, growing) or stdin."""
    if source is None or source == "-":
        for line in sys.stdin:
            yield line
        return

    with open(source, "r", errors="replace") as f:
        f.seek(0, 2)  # start at EOF — we only care about lines from now on
        while True:
            line = f.readline()
            if line:
                yield line
            else:
                time.sleep(0.2)


def wait_for_root(pattern: re.Pattern, source: str | None, root_layer: int,
                   survivor_mac: str | None, t0: float, timeout: float | None):
    """Blocks until a matching line reports `root_layer`; returns elapsed
    seconds since t0, or None on timeout."""
    for line in follow_lines(source):
        if timeout is not None and time.monotonic() - t0 > timeout:
            return None
        m = pattern.search(line)
        if not m:
            continue
        gd = m.groupdict()
        if "layer" not in gd:
            continue
        try:
            layer = int(gd["layer"])
        except ValueError:
            continue
        mac = gd.get("mac")
        if survivor_mac and mac and mac.upper() != survivor_mac.upper():
            continue
        if layer == root_layer:
            return time.monotonic() - t0
    return None


def run_once(args, pattern: re.Pattern) -> float | None:
    input(
        "\nCut power to the root now, then press Enter to start the timer "
        "(the timer starts on Enter, not on the power cut — account for that "
        "gap manually if it matters)..."
    )
    t0 = time.monotonic()
    print("Timing... waiting for a log line reporting the survivor as root.")
    elapsed = wait_for_root(
        pattern, args.source, args.root_layer, args.survivor_mac, t0, args.timeout
    )
    if elapsed is None:
        print("TIMEOUT — no matching log line seen within --timeout.", file=sys.stderr)
    else:
        print(f"Recovery time: {elapsed:.2f}s")
    return elapsed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", default=None, help="log file to tail (default: read stdin)")
    ap.add_argument("--pattern", default=DEFAULT_PATTERN, help="regex with named groups `layer` (required) and `mac` (optional)")
    ap.add_argument("--root-layer", type=int, default=0, help="LAYER value that means 'this node is now root' (default 0 — see NOTE in --help)")
    ap.add_argument("--survivor-mac", default=None, help="only count log lines from this MAC as the survivor (default: any device reporting root-layer)")
    ap.add_argument("--dead-node", default=None, help="MAC of the node whose power will be cut (informational, printed in the summary only)")
    ap.add_argument("--timeout", type=float, default=180.0, help="give up after this many seconds per run (default 180)")
    ap.add_argument("--repeat", type=int, default=1, help="number of power-cycle runs to prompt for (default 1)")
    args = ap.parse_args()

    try:
        pattern = re.compile(args.pattern)
    except re.error as e:
        print(f"error: bad --pattern: {e}", file=sys.stderr)
        return 1
    if "layer" not in pattern.groupindex:
        print("error: --pattern must define a named group `layer`", file=sys.stderr)
        return 1

    if args.dead_node:
        print(f"Dead node under test: {args.dead_node}")

    results = []
    for i in range(args.repeat):
        print(f"\n=== Run {i + 1}/{args.repeat} ===")
        elapsed = run_once(args, pattern)
        if elapsed is not None:
            results.append(elapsed)

    if not results:
        print("\nNo successful runs.", file=sys.stderr)
        return 1

    print("\n=== Summary ===")
    print(f"runs:   {[f'{r:.2f}' for r in results]}")
    print(f"min:    {min(results):.2f}s")
    print(f"median: {statistics.median(results):.2f}s")
    print(f"max:    {max(results):.2f}s")
    if len(results) < args.repeat:
        print(f"({args.repeat - len(results)} run(s) timed out and are excluded above)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
