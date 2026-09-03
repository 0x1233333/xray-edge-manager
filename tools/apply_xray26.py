#!/usr/bin/env python3
"""Apply the v0.0.37-xray26 unified patch to production xem.sh (same dir or argv)."""
import base64, gzip, pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parent.parent
parts = root / "tools" / "b64parts"
target = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / "xem.sh"
b64 = "".join((parts / f"p{i}.txt").read_text().strip() for i in range(8))
patch = gzip.decompress(base64.b64decode(b64))
patch_path = root / "xem.sh.patch"
patch_path.write_bytes(patch)
subprocess.check_call(["patch", "-p1", "--directory", str(root), "-i", str(patch_path)])
patch_path.unlink(missing_ok=True)
print("patched", target)
