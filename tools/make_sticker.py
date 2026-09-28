#!/usr/bin/env python3
"""
make_sticker.py — generates one unit's factory identity (POC-BRIEF.md §3/§4.1).

Produces, under --out-dir/<id>/:
  - sticker.csv   NVS CSV source (namespace "siot_fact": id, pop)
  - sticker.bin   flashable image of the **nvs_factory** partition (via ESP-IDF's
                  nvs_partition_gen.py — requires $IDF_PATH; skipped with a
                  warning if not found, so this still runs without ESP-IDF
                  installed). Size defaults to 0x8000 = the nvs_factory
                  partition of firmware/apps/*/partitions_*.csv (OTA blueprint
                  §1); flash it with tools/flash.sh.
  - sticker.json  the sticker QR payload as raw JSON (always written, so the
                  QR contents are inspectable even without the `qrcode` lib)
  - sticker.png   QR code PNG for the physical label, with the id and MAC
                  printed under the code (requires `pip install qrcode[pil]`;
                  skipped with a warning if not installed — tools/flash.sh
                  installs it into the IDF python env on first use)

  --qr-only DIR   regenerate only sticker.png from an existing DIR/sticker.json
                  (units created before the PNG existed, or after a MAC fix)

`id`/`pop` are generated (secrets-random) unless overridden. The real MAC is
NEVER generated here — it's read from hardware at firmware boot
(esp_read_mac) and never stored in NVS (blueprint §2). Pass --mac for the
sticker's printed/QR MAC field (read it off the board/chip silkscreen, or via
`esptool.py read_mac` against the connected device before running this tool).

QR payload schema (pinned — the Flutter app's sticker-scan feature is built
against this exact shape, do not change without updating both sides):
    {"id": "<id>", "mac": "AA:BB:CC:DD:EE:FF", "pop": "<pop>"}

Usage:
    python3 make_sticker.py --mac AA:BB:CC:DD:EE:FF
    python3 make_sticker.py --id dev-002 --pop <32-char-secret> --mac ...
"""
import argparse
import csv
import json
import os
import re
import secrets
import shutil
import string
import subprocess
import sys
from pathlib import Path

# Keep in sync with firmware/components/platform/siot_identity/include/siot_identity.h
SIOT_ID_MAX_LEN = 31
SIOT_POP_MAX_LEN = 63
SIOT_POP_MIN_LEN = 16  # blueprint §0: sticker POP should be 16+ chars

MAC_RE = re.compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")

# Default size of the generated .bin = the read-only "nvs_factory" partition
# of the product firmware (firmware/apps/{board,node}/partitions_*.csv, OTA
# blueprint §1.1/§1.2: 0x8000 at 0x3E0000 on the node, 0x7E0000 on the board).
# The round-1 POCs (pocs/) wrote the same namespace into their 0x6000 "nvs"
# partition instead — pass --nvs-size 0x6000 for those.
DEFAULT_NVS_SIZE = 0x8000


def gen_id() -> str:
    return "dev-" + secrets.token_hex(4)


def gen_pop(length: int = 24) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def validate_id(id_: str) -> str:
    if not id_ or len(id_) > SIOT_ID_MAX_LEN:
        raise ValueError(f"--id must be 1..{SIOT_ID_MAX_LEN} chars, got {id_!r}")
    return id_


def validate_pop(pop: str) -> str:
    if len(pop) < SIOT_POP_MIN_LEN or len(pop) > SIOT_POP_MAX_LEN:
        raise ValueError(
            f"--pop must be {SIOT_POP_MIN_LEN}..{SIOT_POP_MAX_LEN} chars, "
            f"got {len(pop)}"
        )
    return pop


def validate_mac(mac: str | None) -> str | None:
    if mac is None:
        return None
    if not MAC_RE.match(mac):
        raise ValueError(f"--mac must look like AA:BB:CC:DD:EE:FF, got {mac!r}")
    return mac.upper()


def write_nvs_csv(path: Path, id_: str, pop: str) -> None:
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["key", "type", "encoding", "value"])
        w.writerow(["siot_fact", "namespace", "", ""])
        w.writerow(["id", "data", "string", id_])
        w.writerow(["pop", "data", "string", pop])


def find_nvs_partition_gen() -> Path | None:
    idf_path = os.environ.get("IDF_PATH")
    if not idf_path:
        return None
    candidate = (
        Path(idf_path)
        / "components"
        / "nvs_flash"
        / "nvs_partition_generator"
        / "nvs_partition_gen.py"
    )
    return candidate if candidate.is_file() else None


def generate_nvs_bin(csv_path: Path, bin_path: Path, size: int) -> bool:
    gen = find_nvs_partition_gen()
    if gen is None:
        print(
            "WARNING: $IDF_PATH not set (or nvs_partition_gen.py not found under "
            "it) — skipping sticker.bin. Set up your ESP-IDF environment "
            "(`source .../export.sh`) and re-run to produce the flashable "
            "NVS image; sticker.csv is still written so you can run "
            "nvs_partition_gen.py yourself later.",
            file=sys.stderr,
        )
        return False
    subprocess.run(
        [
            sys.executable,
            str(gen),
            "generate",
            str(csv_path),
            str(bin_path),
            hex(size),
        ],
        check=True,
    )
    return True


def generate_qr_png(payload: dict, png_path: Path) -> bool:
    try:
        import qrcode
    except ImportError:
        print(
            "WARNING: `qrcode` not installed (`pip install qrcode[pil]`) — "
            "skipping sticker.png. sticker.json has the same payload.",
            file=sys.stderr,
        )
        return False
    img = qrcode.make(json.dumps(payload, separators=(",", ":"))).convert("RGB")
    try:  # id + MAC under the code so the printed label is readable by a human too
        from PIL import Image, ImageDraw, ImageFont
        font = ImageFont.load_default()
        lines = [f"id  {payload.get('id') or ''}", f"mac {payload.get('mac') or '(not set)'}"]
        line_h = 14
        canvas = Image.new("RGB", (img.width, img.height + line_h * len(lines) + 8), "white")
        canvas.paste(img, (0, 0))
        draw = ImageDraw.Draw(canvas)
        for i, text in enumerate(lines):
            draw.text((16, img.height + 2 + i * line_h), text, fill="black", font=font)
        img = canvas
    except Exception as e:  # noqa: BLE001 — the bare QR is still a valid sticker
        print(f"WARNING: label text skipped ({e})", file=sys.stderr)
    img.save(str(png_path))
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--id", default=None, help="factory id (default: random dev-XXXXXXXX)")
    ap.add_argument("--pop", default=None, help="factory pop secret (default: random 24 chars)")
    ap.add_argument("--mac", default=None, help="unit's real MAC, AA:BB:CC:DD:EE:FF (for the sticker only)")
    ap.add_argument("--out-dir", default="./stickers", help="output root (default ./stickers)")
    ap.add_argument("--qr-only", default=None, metavar="DIR",
                    help="only (re)write DIR/sticker.png from DIR/sticker.json; nothing else is touched")
    ap.add_argument(
        "--nvs-size",
        default=hex(DEFAULT_NVS_SIZE),
        help=f"nvs partition size for sticker.bin (default {hex(DEFAULT_NVS_SIZE)}) "
        "— must match your project's partitions.csv 'nvs' entry",
    )
    args = ap.parse_args()

    if args.qr_only:
        d = Path(args.qr_only)
        json_path, png_path = d / "sticker.json", d / "sticker.png"
        if not json_path.is_file():
            print(f"error: no {json_path}", file=sys.stderr)
            return 1
        ok = generate_qr_png(json.loads(json_path.read_text()), png_path)
        print(f"png:  {png_path if ok else '(skipped — see warning above)'}")
        return 0 if ok else 1

    try:
        id_ = validate_id(args.id or gen_id())
        pop = validate_pop(args.pop or gen_pop())
        mac = validate_mac(args.mac)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if mac is None:
        print(
            "WARNING: no --mac given — sticker.json/.png will carry "
            "\"mac\": null. Re-run with --mac once you've read it off the "
            "unit (esptool.py read_mac) so the printed sticker is complete.",
            file=sys.stderr,
        )

    out_dir = Path(args.out_dir) / id_
    out_dir.mkdir(parents=True, exist_ok=True)

    csv_path = out_dir / "sticker.csv"
    bin_path = out_dir / "sticker.bin"
    json_path = out_dir / "sticker.json"
    png_path = out_dir / "sticker.png"

    write_nvs_csv(csv_path, id_, pop)
    bin_ok = generate_nvs_bin(csv_path, bin_path, int(args.nvs_size, 0))

    payload = {"id": id_, "mac": mac, "pop": pop}
    json_path.write_text(json.dumps(payload, indent=2) + "\n")
    png_ok = generate_qr_png(payload, png_path)

    print(f"id:   {id_}")
    print(f"pop:  {pop}")
    print(f"mac:  {mac or '(not set)'}")
    print(f"csv:  {csv_path}")
    print(f"bin:  {bin_path if bin_ok else '(skipped — see warning above)'}")
    print(f"json: {json_path}")
    print(f"png:  {png_path if png_ok else '(skipped — see warning above)'}")
    print(
        "\nTo flash the identity alone (nvs_factory offset from the app's "
        "partition table: node 0x3E0000, board 0x7E0000):\n"
        f"  esptool.py write_flash 0x3E0000 {bin_path}\n"
        "or app + partition table + identity in one go:\n"
        f"  tools/flash.sh node <port> {id_}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
