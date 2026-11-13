#!/usr/bin/env python3
"""Inflate every stream the Goose tests wrote and compare it byte for byte.

A compressor that returns Ok with a plausible size can still emit a broken
stream, so the Goose assertions are not enough on their own. This runs an
independent decoder (CPython's zlib) over each artifact `test/contract.goose`
produced: one stream per wrapper and level, the sizes that sit on deflate's
block boundaries, incompressible input, concatenated members, the trained
stream, and the empty input.

Artifacts are discovered, not listed, so adding a case on the Goose side needs
no change here.

    python3 scripts/check_gzip.py [dir]      # dir defaults to build/tmp
"""

from __future__ import annotations

import gzip
import sys
import zlib
from pathlib import Path

# File suffix -> decoder. The Goose exporter names its output accordingly.
DECODERS = {".gz": "gzip", ".zlib": "zlib", ".deflate": "deflate"}
# Named artifacts and what each must inflate to, relative to the body.
NAMED = {
    "twice_a.gz": 1,
    "twice_b.gz": 1,
    "twomembers.gz": 2,
    "trained.gz": 1,
    "empty.gz": 0,
}
EXPECTED_STREAMS = 25


def inflate(data: bytes, kind: str) -> bytes:
    if kind == "gzip":
        return gzip.decompress(data)
    if kind == "zlib":
        return zlib.decompress(data, 15)
    return zlib.decompress(data, -15)


class Checker:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.checked = 0
        self.failures = 0
        self.sizes: dict[str, int] = {}

    def fail(self, what: str, why: str) -> None:
        print(f"[FAIL] {what}: {why}")
        self.failures += 1

    def check(self, rel: str, kind: str, want: bytes) -> None:
        path = self.root / rel
        if not path.exists():
            self.fail(rel, "missing")
            return
        raw = path.read_bytes()
        try:
            got = inflate(raw, kind)
        except Exception as exc:  # noqa: BLE001 - any decoder complaint is a failure
            self.fail(rel, str(exc))
            return
        if got != want:
            self.fail(rel, f"inflated {len(got)} bytes, expected {len(want)}")
            return
        if kind == "gzip":
            if raw[:2] != b"\x1f\x8b" or raw[2] != 8:
                self.fail(rel, "not a gzip member")
                return
            if raw[4:8] != b"\x00\x00\x00\x00":
                self.fail(rel, "mtime is not zero, so output is not reproducible")
                return
        self.checked += 1
        self.sizes[rel] = len(raw)


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "build/tmp")
    body_path = root / "body.txt"
    if not body_path.exists():
        print(f"error: {body_path} missing; run the Goose tests first", file=sys.stderr)
        return 2
    body = body_path.read_bytes()
    c = Checker(root)

    # One stream per wrapper and level, discovered from the matrix directory.
    matrix = sorted((root / "matrix").glob("*")) if (root / "matrix").is_dir() else []
    if not matrix:
        c.fail("matrix/", "no streams written")
    for path in matrix:
        kind = DECODERS.get(path.suffix)
        if kind is None:
            c.fail(f"matrix/{path.name}", f"no decoder for suffix {path.suffix}")
            continue
        c.check(f"matrix/{path.name}", kind, body)

    # Sizes on deflate's seams, each beside the input it came from.
    for bin_path in sorted(root.glob("size_*.bin")):
        n = bin_path.stem.removeprefix("size_")
        c.check(f"size_{n}.gz", "gzip", bin_path.read_bytes())

    # Incompressible input: the expansion path must still be valid gzip.
    noise_path = root / "incompressible.bin"
    if noise_path.exists():
        c.check("incompressible.gz", "gzip", noise_path.read_bytes())
    else:
        c.fail("incompressible.bin", "missing")

    # The trained table on a body it never sampled.
    c.check("trained_half.gz", "gzip", body[len(body) // 2 :])

    # Named cases.
    for name, copies in NAMED.items():
        c.check(name, "gzip", body * copies)

    # Two runs of the same input must be the same bytes, which no decoder can
    # tell us.
    a, b = root / "twice_a.gz", root / "twice_b.gz"
    if a.exists() and b.exists():
        if a.read_bytes() == b.read_bytes():
            print("[ok]   determinism            two runs gave identical bytes")
        else:
            c.fail("determinism", "two runs of the same input differ")

    # A size sanity check against CPython's zlib: igzip is tuned for speed, so
    # this only catches a compressor that has stopped compressing.
    for rel, level, slack in [("matrix/gzip_1.gz", 1, 1.25), ("matrix/gzip_3.gz", 9, 1.15)]:
        if rel not in c.sizes:
            continue
        probe = zlib.compressobj(level, zlib.DEFLATED, 31)
        reference = len(probe.compress(body) + probe.flush())
        limit = int(reference * slack)
        if c.sizes[rel] > limit:
            c.fail(rel, f"{c.sizes[rel]} bytes, over {limit} (zlib level {level} gives {reference})")
        else:
            print(f"[ok]   ratio vs zlib l{level:<2}       {c.sizes[rel]:>7} bytes vs {reference}")

    # The trained table exists to beat level 0's default on bodies of its kind.
    if "matrix/gzip_0.gz" in c.sizes and "trained.gz" in c.sizes:
        saved = c.sizes["matrix/gzip_0.gz"] - c.sizes["trained.gz"]
        if saved <= 0:
            c.fail("trained.gz", "did not beat the level 0 default table")
        else:
            print(f"[ok]   trained table saves {saved} bytes over the level 0 default")

    for rel in ["matrix/gzip_0.gz", "matrix/gzip_1.gz", "matrix/gzip_3.gz", "trained.gz"]:
        if rel in c.sizes:
            pct = 100.0 * c.sizes[rel] / len(body)
            print(f"[ok]   {rel:<22} {c.sizes[rel]:>7} bytes  {pct:5.1f}% of {len(body)}")

    print(f"\n{c.checked}/{EXPECTED_STREAMS} streams valid")
    if c.checked != EXPECTED_STREAMS:
        c.fail("stream count", f"checked {c.checked}, expected {EXPECTED_STREAMS}")
    return 1 if c.failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
