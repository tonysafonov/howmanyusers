#!/usr/bin/env python3
"""Aggregate py-spy collapsed stacks (`py-spy record --format raw`, as written by pyspy.sh). Stdlib only.

    python3 stacks.py top      prof.txt [--min 3]            # inclusive share per frame, top leaves, idle estimate
    python3 stacks.py children prof.txt solve_dependencies    # where a frame's time goes (its direct callees)
    python3 stacks.py match    prof.txt 'get_dependant' 'logging.*flush' 'sqlalchemy'   # share per regex
    python3 stacks.py diff     a.txt b.txt [--min 1]          # inclusive shares side by side (A/B of one endpoint)

Shares are of the in-request samples (stacks that contain the request entry frame, default `run_asgi`; change it
with --entry, e.g. `handle` for other servers; global options go first: `stacks.py --entry handle top f.txt`) unless --all. Inclusive = the frame appears anywhere in the stack,
counted once per sample: that is the number to quote ("28.8 % of a request is in get_dependant").

Read shares only from a profile taken at saturation: below it, the event loop's idle wait (uvloop's C `run`, or
`select`) is sampled as busy and inflates everything that sits above it.
"""

import argparse
import collections
import re
import sys

PATH_RE = re.compile(r" \(.*?/(?:site-packages|dist-packages|src|lib/python3\.\d+t?)/")
LINE_RE = re.compile(r":\d+\)")
PROCESS_RE = re.compile(r'^(?:process \d+:".*?";)+')  # py-spy's root frames (one per process with --subprocesses)
IDLE_LEAF = re.compile(r"^(run \(|select \(|poll \(|_run_once \(|epoll)")


def short(frame: str) -> str:
    """`func (/long/path/site-packages/pkg/mod.py:123)` -> `func (pkg/mod.py)`."""
    return LINE_RE.sub(")", PATH_RE.sub(" (", frame))


def load(path: str):
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip()
        if not line or " " not in line:
            continue
        stack, n = line.rsplit(" ", 1)
        try:
            count = int(n)
        except ValueError:
            continue
        stack = PROCESS_RE.sub("", stack)
        yield [short(f) for f in stack.split(";")], count


def in_request(frames, entry):
    return entry is None or any(f.startswith(entry) for f in frames)


def inclusive(path, entry):
    total = 0
    inc = collections.Counter()
    leaf = collections.Counter()
    for frames, n in load(path):
        if not in_request(frames, entry):
            continue
        total += n
        leaf[frames[-1]] += n
        for f in set(frames):
            inc[f] += n
    return total, inc, leaf


def cmd_top(a):
    entry = None if a.all else a.entry
    everything = idle = 0
    for frames, n in load(a.file):
        everything += n
        if IDLE_LEAF.match(frames[-1]):
            idle += n
    total, inc, leaf = inclusive(a.file, entry)
    if not total:
        sys.exit(f"no samples{'' if entry is None else f' containing {entry!r} (try --entry or --all)'}")
    scope = "all samples" if entry is None else f"in-request samples ({100 * total / everything:.1f}% of {everything})"
    print(f"{total} {scope}")
    if idle / everything > 0.15:
        print(f"WARNING: {100 * idle / everything:.0f}% of all samples end in an event-loop wait: the worker was not"
              " saturated; with --all the shares are inflated, and in-request shares may miss queueing")
    print(f"\ninclusive (>= {a.min}%):")
    for k, v in inc.most_common(200):
        if 100 * v / total >= a.min:
            print(f"{100 * v / total:6.1f}%  {k}")
    print("\nleaf (self time):")
    for k, v in leaf.most_common(a.leaves):
        print(f"{100 * v / total:6.1f}%  {k}")


def cmd_children(a):
    entry = None if a.all else a.entry
    total = 0
    child = collections.Counter()
    grand = collections.Counter()
    for frames, n in load(a.file):
        if not in_request(frames, entry):
            continue
        total += n
        idx = next((i for i, f in enumerate(frames) if f.startswith(a.frame)), None)
        if idx is None:
            continue
        c = frames[idx + 1] if idx + 1 < len(frames) else "<self>"
        child[c] += n
        if idx + 2 < len(frames):
            grand[f"{c}  >  {frames[idx + 2]}"] += n
    s = sum(child.values())
    if not total or not s:
        sys.exit(f"no samples under {a.frame!r}")
    print(f"{a.frame}: {100 * s / total:.1f}% of {total} samples; its direct callees:")
    for k, v in child.most_common(15):
        print(f"{100 * v / total:6.1f}%  {k}")
    print("one level deeper:")
    for k, v in grand.most_common(15):
        print(f"{100 * v / total:6.1f}%  {k}")


def cmd_match(a):
    entry = None if a.all else a.entry
    pats = [(p, re.compile(p)) for p in a.patterns]
    total = 0
    hit = collections.Counter()
    for frames, n in load(a.file):
        if not in_request(frames, entry):
            continue
        total += n
        joined = ";".join(frames)
        for p, rx in pats:
            if rx.search(joined):
                hit[p] += n
    if not total:
        sys.exit("no samples")
    print(f"{total} samples")
    for p, _ in pats:
        print(f"{100 * hit[p] / total:6.1f}%  {p}")


def cmd_diff(a):
    entry = None if a.all else a.entry
    ta, ia, _ = inclusive(a.a, entry)
    tb, ib, _ = inclusive(a.b, entry)
    if not ta or not tb:
        sys.exit("no samples in one of the files")
    keys = sorted(set(ia) | set(ib), key=lambda k: -max(ia[k] / ta, ib[k] / tb))
    print(f"{'A %':>7} {'B %':>7} {'B-A':>7}  frame   (A={a.a}, {ta} samples; B={a.b}, {tb} samples)")
    for k in keys:
        pa, pb = 100 * ia[k] / ta, 100 * ib[k] / tb
        if max(pa, pb) >= a.min:
            print(f"{pa:7.1f} {pb:7.1f} {pb - pa:+7.1f}  {k}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--entry", default="run_asgi", help="frame that marks a request (default run_asgi)")
    ap.add_argument("--all", action="store_true", help="use all samples, not only in-request ones")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("top")
    p.add_argument("file")
    p.add_argument("--min", type=float, default=3.0)
    p.add_argument("--leaves", type=int, default=20)
    p.set_defaults(fn=cmd_top)
    p = sub.add_parser("children")
    p.add_argument("file")
    p.add_argument("frame", help="frame name prefix, e.g. solve_dependencies")
    p.set_defaults(fn=cmd_children)
    p = sub.add_parser("match")
    p.add_argument("file")
    p.add_argument("patterns", nargs="+")
    p.set_defaults(fn=cmd_match)
    p = sub.add_parser("diff")
    p.add_argument("a")
    p.add_argument("b")
    p.add_argument("--min", type=float, default=1.0)
    p.set_defaults(fn=cmd_diff)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
