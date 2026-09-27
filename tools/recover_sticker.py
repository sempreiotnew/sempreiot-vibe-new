#!/usr/bin/env python3
"""
recover_sticker.py — rebuild the sticker of a unit whose identity is already in
its flash, without inventing a new id/pop.

Round-1 POC units keep {id, pop} in namespace "siot_fact" of the ordinary "nvs"
partition (0x9000, 0x6000); Phase 1 units keep it in "nvs_factory". This tool
reads both regions over USB, extracts id + pop with ESP-IDF's nvs_tool.py,
reads the MAC, and runs make_sticker.py --id --pop --mac so tools/stickers/<id>/
gets a flashable nvs_factory image + QR. Then: tools/flash.sh <app> <port> <id>.

    python3 tools/recover_sticker.py <port> [--out-dir ./stickers]

Needs the ESP-IDF environment ($IDF_PATH) for esptool and nvs_tool.py.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# (label, offset, size): the POC "nvs" partition, then both Phase 1 nvs_factory offsets.
REGIONS = [
    ("nvs (POC)", 0x9000, 0x6000),
    ("nvs_factory (4 MB table)", 0x3E0000, 0x8000),
    ("nvs_factory (8 MB table)", 0x7E0000, 0x8000),
    ("nvs_factory (8 MB table, before 2026-09-27)", 0x720000, 0x8000),
]
KV_RE = re.compile(r"^\s*siot_fact:(id|pop)\s*=\s*(.*?)\s*$")


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def esptool(port, *args):
    """esptool exits 2 both for a usage error and when it cannot connect
    (port busy — e.g. idf.py monitor still open — or chip not answering).
    Show its message instead of a traceback."""
    try:
        return run([sys.executable, "-m", "esptool", "--chip", "esp32s3", "-p", port, *args])
    except subprocess.CalledProcessError as e:
        msg = (e.stdout or "") + (e.stderr or "")
        print(f"esptool {args[0]} failed on {port}:\n{msg.strip()}", file=sys.stderr)
        print("\nclose any 'idf.py monitor' / serial terminal on that port and retry; "
              "if it persists, hold BOOT while pressing RESET to force download mode.",
              file=sys.stderr)
        raise SystemExit(1)


def read_mac(port) -> str:
    out = esptool(port, "read_mac").stdout
    m = re.search(r"MAC:\s*([0-9a-fA-F:]{17})", out)
    if not m:
        raise SystemExit("could not read the MAC:\n" + out)
    return m.group(1).upper()


def flash_size_bytes(port) -> int:
    out = esptool(port, "flash_id").stdout
    m = re.search(r"Detected flash size:\s*(\d+)MB", out)
    return int(m.group(1)) * 1024 * 1024 if m else 0


def dump_identity(port, idf_path: Path, offset: int, size: int):
    nvs_tool = idf_path / "components/nvs_flash/nvs_partition_tool/nvs_tool.py"
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        img = Path(f.name)
    try:
        esptool(port, "read_flash", hex(offset), hex(size), str(img))
        out = run([sys.executable, str(nvs_tool), "-d", "minimal", str(img)]).stdout
    except subprocess.CalledProcessError as e:
        return None  # not an NVS image (blank / other data)
    finally:
        img.unlink(missing_ok=True)
    found = {}
    for line in out.splitlines():
        m = KV_RE.match(line)
        if m:
            found[m.group(1)] = m.group(2).rstrip("\x00")  # nvs_tool prints the string's NUL
    return found if "id" in found and "pop" in found else None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port")
    ap.add_argument("--out-dir", default=str(Path(__file__).parent / "stickers"))
    args = ap.parse_args()

    idf_path = os.environ.get("IDF_PATH")
    if not idf_path:
        print("error: source ~/.espressif/tools/activate_idf_v5.5.2.sh first ($IDF_PATH unset)", file=sys.stderr)
        return 1
    idf_path = Path(idf_path)

    mac = read_mac(args.port)
    size = flash_size_bytes(args.port)
    print(f"unit MAC {mac}, flash {size // (1024 * 1024) or '?'} MB")

    identity = None
    for label, offset, region_size in REGIONS:
        if size and offset + region_size > size:
            continue
        found = dump_identity(args.port, idf_path, offset, region_size)
        print(f"  {label} @ {hex(offset)}: {'id=' + found['id'] if found else 'no identity'}")
        if found and identity is None:
            identity = found
    if identity is None:
        print("error: no siot_fact id/pop anywhere on this unit — use make_sticker.py to create one",
              file=sys.stderr)
        return 1

    make = Path(__file__).parent / "make_sticker.py"
    cmd = [sys.executable, str(make), "--id", identity["id"], "--pop", identity["pop"],
           "--mac", mac, "--out-dir", args.out_dir]
    print("running:", " ".join(cmd[1:]))
    return subprocess.call(cmd)


if __name__ == "__main__":
    raise SystemExit(main())
