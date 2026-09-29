#!/usr/bin/env python3
"""Print a flash / partition / RAM usage summary for one idf.py build directory.

    build_summary.py <build-dir> [label]        summary of one build directory
    build_summary.py --module 4MB|8MB           print the module that flash size means

Reads only build products (flasher_args.json, config/sdkconfig.json,
partition_table/partition-table.bin, the app .bin and .map) — nothing is rebuilt.
Called by firmware/build.sh after every successful board/node build; safe to run by
hand on any existing build directory.

The modules the product ships on (supplier recommendation, 2026-09-25) — the single
place firmware/build.sh and tools/flash.sh take module names from:
"""
import json
import os
import subprocess
import sys

# flash size as esptool spells it -> (module, PSRAM bytes, short description)
MODULES = {
    "8MB": ("ESP32-S3-WROOM-1-N8R8", 8 << 20, "8 MB flash + 8 MB octal PSRAM; the board"),
    "4MB": ("ESP32-S3-WROOM-1-N4",   0,       "4 MB flash, no PSRAM; the node and the 4 MB bench boards"),
}

IDF_PATH = os.environ.get("IDF_PATH")
if not IDF_PATH:
    sys.exit("build_summary.py: IDF_PATH is not set (source activate_idf_v5.5.2.sh)")
sys.path.insert(0, os.path.join(IDF_PATH, "components", "partition_table"))
import gen_esp32part  # noqa: E402  (ESP-IDF's own partition-table parser)


def human(n):
    for unit, div in (("MB", 1 << 20), ("KB", 1 << 10)):
        if n >= div and n % div == 0:
            return f"{n // div} {unit}"
        if n >= div:
            return f"{n / div:.1f} {unit}"
    return f"{n} B"


def pct(used, total):
    return f"{100.0 * used / total:5.1f}%" if total else "   - "


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if sys.argv[1] == "--module":
        m = MODULES.get(sys.argv[2].upper() if len(sys.argv) > 2 else "")
        if not m:
            sys.exit(f"build_summary.py: unknown flash size {sys.argv[2:]}; known: {', '.join(MODULES)}")
        print(m[0])
        return
    build = sys.argv[1]
    label = sys.argv[2] if len(sys.argv) > 2 else build

    with open(os.path.join(build, "flasher_args.json")) as f:
        fa = json.load(f)
    flash_size_str = fa["flash_settings"]["flash_size"]        # "4MB" / "8MB"
    if flash_size_str == "keep":
        # Signed images (docs/ota/signing-key.md): esptool is told to keep the
        # flash size of the image header, so the number is in the config.
        with open(os.path.join(build, "config", "sdkconfig.json")) as f:
            flash_size_str = json.load(f)["ESPTOOLPY_FLASHSIZE"]
    flash_total = int(flash_size_str.rstrip("B").rstrip("M")) << 20
    files = {int(off, 16): rel for off, rel in fa["flash_files"].items()}
    sizes = {off: os.path.getsize(os.path.join(build, rel)) for off, rel in files.items()}
    app_off = int(fa["app"]["offset"], 16)
    app_rel = fa["app"]["file"]
    app_size = sizes[app_off]

    with open(os.path.join(build, "partition_table", "partition-table.bin"), "rb") as f:
        table = gen_esp32part.PartitionTable.from_binary(f.read())
    type_names = {v: k for k, v in gen_esp32part.TYPES.items()}

    def sub_name(p):
        for k, v in gen_esp32part.SUBTYPES.get(p.type, {}).items():
            if v == p.subtype:
                return k
        return f"0x{p.subtype:02x}"

    module, psram, module_desc = MODULES.get(flash_size_str, (f"unknown {flash_size_str} module", 0, ""))
    try:
        with open(os.path.join(build, "config", "sdkconfig.json")) as f:
            cfg = json.load(f)
    except OSError:
        cfg = {}

    table_csv = cfg.get("PARTITION_TABLE_CUSTOM_FILENAME") or cfg.get("PARTITION_TABLE_FILENAME") or "?"
    print()
    print(f"==> Flash usage: {label}  ·  {module}  ·  {flash_size_str} flash ({flash_total:,} B)  ·  table {table_csv}")
    hdr = f"  {'Partition':<16}{'Type/Sub':<15}{'Offset':>9}  {'Size':>9} {'':>8}  {'Written':>9}  {'Used':>6}  {'Free':>9}"
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))

    def row(name, kind, off, size, written=None, note=""):
        w = f"{written:,}" if written is not None else ""
        u = pct(written, size) if written is not None else ""
        fr = f"{size - written:,}" if written is not None else ""
        print(f"  {name:<16}{kind:<15}{off:>#9x}  {size:>9,} {human(size):>8}  {w:>9}  {u:>6}  {fr:>9}  {note}")

    # Region before the first partition: bootloader + the partition table itself.
    first = min(p.offset for p in table)
    pt_off = int(fa["partition-table"]["offset"], 16)
    bl_off = int(fa["bootloader"]["offset"], 16)
    row("bootloader", "(pre-table)", bl_off, pt_off - bl_off, sizes.get(bl_off))
    row("partition-table", "(pre-table)", pt_off, first - pt_off, sizes.get(pt_off))

    app_parts = [p for p in table if p.type == gen_esp32part.TYPES["app"]]
    end = first
    for p in sorted(table, key=lambda p: p.offset):
        kind = f"{type_names.get(p.type, p.type)}/{sub_name(p)}"
        written = sizes.get(p.offset)
        note = ""
        if p.type == gen_esp32part.TYPES["app"]:
            if p.offset == app_off:
                note = f"<- {app_rel}"
            else:
                written = app_size
                note = "(OTA slot: same image after update)"
            if app_size > p.size:
                note += "  !! IMAGE DOES NOT FIT"
        row(p.name, kind, p.offset, p.size, written, note)
        end = max(end, p.offset + p.size)

    print()
    smallest = min(app_parts, key=lambda p: p.size) if app_parts else None
    if smallest:
        free = smallest.size - app_size
        print(f"  App image  : {app_size:,} B ({human(app_size)})  in {smallest.name} {smallest.size:,} B "
              f"({human(smallest.size)})  ->  {pct(app_size, smallest.size).strip()} used, {free:,} B free")
    unassigned = flash_total - end
    print(f"  Flash      : {flash_total:,} B total, partitions end at {end:#x} "
          f"({end:,} B)  ->  {unassigned:,} B ({human(unassigned)}) unassigned")
    if end > flash_total:
        print("  !! PARTITION TABLE EXCEEDS THE FLASH SIZE")

    # PSRAM: what the module has vs. what this build enables (CONFIG_SPIRAM).
    spiram = bool(cfg.get("SPIRAM", False))
    if psram:
        mode = "octal" if cfg.get("SPIRAM_MODE_OCT") else ("quad" if cfg.get("SPIRAM_MODE_QUAD") else "?")
        state = f"enabled in this build ({mode}, {cfg.get('SPIRAM_SPEED', '?')} MHz)" if spiram \
            else "NOT enabled in this build (CONFIG_SPIRAM=n) — the 8 MB PSRAM is unused"
        print(f"  PSRAM      : {module} has {psram >> 20} MB  ->  {state}")
    elif spiram:
        print(f"  PSRAM      : !! CONFIG_SPIRAM=y but {module} has no PSRAM — boot will fail "
              f"unless CONFIG_SPIRAM_IGNORE_NOTFOUND=y")
    else:
        print(f"  PSRAM      : none on {module}; not enabled in this build (correct)")

    # Static RAM / flash segments from the linker map (esp-idf-size, bundled with IDF).
    map_file = os.path.join(build, os.path.splitext(app_rel)[0] + ".map")
    if os.path.exists(map_file):
        try:
            out = subprocess.run([sys.executable, "-m", "esp_idf_size", "--format", "json", map_file],
                                 capture_output=True, text=True, check=True).stdout
            s = json.loads(out)
            parts = []
            for lbl, used, total in (("IRAM", "used_iram", "iram_total"),
                                     ("DRAM", "used_dram", "dram_total"),
                                     ("D/IRAM", "used_diram", "diram_total")):
                if s.get(total):
                    parts.append(f"{lbl} {s[used]:,}/{s[total]:,} B ({pct(s[used], s[total]).strip()})")
            print(f"  Static RAM : " + "  ·  ".join(parts))
            print(f"  Flash code : .text {s.get('flash_code', 0):,} B  .rodata {s.get('flash_rodata', 0):,} B  "
                  f"(non-RAM flash {s.get('used_flash_non_ram', 0):,} B; total image {s.get('total_size', 0):,} B)")
        except (subprocess.CalledProcessError, ValueError) as e:
            print(f"  (esp_idf_size unavailable: {e})")
    print()


if __name__ == "__main__":
    main()
