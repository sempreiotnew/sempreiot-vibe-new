#!/usr/bin/env python3
"""firmware/tools/ota_catalog.py — the release catalog of ota_release.sh (docs/ota/ota-internet-plan.md).

    ota_catalog.py manifest <dir> <version> <key prefix> <facts.json> <out.json>
    ota_catalog.py add      <catalog.json> <manifest.json> <out.json>
    ota_catalog.py remove   <catalog.json> <version> <out.json>
    ota_catalog.py has      <catalog.json> <version>          exit 0 when published
    ota_catalog.py highest  <catalog.json>                    the highest published version, or nothing
    ota_catalog.py bump     <catalog.json> patch|minor|major  the next version after the highest
    ota_catalog.py cmp      <a> <b>                           -1 / 0 / 1
    ota_catalog.py list     <catalog.json>
    ota_catalog.py central  <dynamodb.json>                   {subId, identityId, name} of one Device row
    ota_catalog.py facts    <out.json> <channel> <bucket> <region> <notes> <git name> <git email> <aws arn> <host> <commit> <central json>
    ota_catalog.py field    <json> <name>

The catalog is what the bucket holds and what the retained MQTT message carries: every published
version, newest first, each with its three images (key, size, SHA-256, project), who published it
and, for a release made for one central, that central. A missing or empty catalog file is an empty
catalog. facts.json = {channel, bucket, region, notes, published_by, central?} from ota_release.sh. Version order is the app's compareFirmwareVersions
(lib/features/central/domain/ota/firmware_version.dart): semver, a pre-release before its release.
"""
import datetime
import hashlib
import json
import os
import re
import struct
import sys

FAMILIES = ("board", "node", "leaf")
APP_DESC_OFFSET = 32          # esp_image_header_t (24) + esp_image_segment_header_t (8)
APP_DESC_MAGIC = 0xABCD5432
VERSION_MAX = 24              # protocol §13.2, safrFwVersionMaxLen in the app
MQTT_MAX = 120_000            # AWS IoT payload limit is 128 KB; keep a margin


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


# ---- versions (same order as the app) ------------------------------------------------------------

def _parse(raw):
    s = raw.strip()
    if s[:1] in ("v", "V"):
        s = s[1:]
    core, _, pre = s.partition("-")
    parts = core.split(".")
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        return None
    return [int(p) for p in parts], pre


def cmp_versions(a, b):
    pa, pb = _parse(a), _parse(b)
    if pa is None or pb is None:
        if pa is not None:
            return 1
        if pb is not None:
            return -1
        return (a > b) - (a < b)
    if pa[0] != pb[0]:
        return 1 if pa[0] > pb[0] else -1
    if pa[1] == pb[1]:
        return 0
    if not pa[1]:
        return 1
    if not pb[1]:
        return -1
    return 1 if pa[1] > pb[1] else -1


# ---- images ----------------------------------------------------------------------------------------

def _cstr(raw):
    s = raw.split(b"\0", 1)[0]
    if not s or any(c < 0x20 or c > 0x7E for c in s):
        return ""
    return s.decode("ascii")


def image_facts(path, family, version):
    """What the tablet checks (firmware_image.dart): magic, version, project — plus size and hash."""
    try:
        data = open(path, "rb").read()
    except OSError as e:
        die(f"{path}: {e.strerror}")
    if len(data) < APP_DESC_OFFSET + 80:
        die(f"{path}: too short to be an ESP-IDF app image")
    magic = struct.unpack_from("<I", data, APP_DESC_OFFSET)[0]
    if magic != APP_DESC_MAGIC:
        die(f"{path}: no esp_app_desc_t (magic 0x{magic:08X})")
    got_version = _cstr(data[APP_DESC_OFFSET + 16:APP_DESC_OFFSET + 48])
    project = _cstr(data[APP_DESC_OFFSET + 48:APP_DESC_OFFSET + 80])
    if got_version != version:
        die(f"{path}: the image says version '{got_version}', not '{version}'")
    if project != f"sempreiot-{family}":
        die(f"{path}: the image is '{project}', not 'sempreiot-{family}'")
    return {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "project": project}


# ---- catalog ---------------------------------------------------------------------------------------

def load(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return {"releases": []}
    with open(path) as f:
        cat = json.load(f)
    cat.setdefault("releases", [])
    return cat


def save(cat, path):
    text = json.dumps(cat, indent=1, sort_keys=False) + "\n"
    if len(text.encode()) > MQTT_MAX:
        die(f"the catalog is {len(text)} B, over the {MQTT_MAX} B an MQTT message may carry: remove old versions")
    with open(path, "w") as f:
        f.write(text)


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sort_releases(cat):
    from functools import cmp_to_key
    cat["releases"].sort(key=cmp_to_key(lambda a, b: cmp_versions(b["version"], a["version"])))


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd, args = argv[1], argv[2:]

    if cmd == "manifest":
        d, version, prefix, facts_path, out = args
        if not re.fullmatch(r"[0-9A-Za-z.+-]{1,%d}" % VERSION_MAX, version):
            die(f"'{version}' is not a firmware version (≤ {VERSION_MAX} chars)")
        with open(facts_path) as f:
            facts = json.load(f)
        images = {}
        for fam in FAMILIES:
            img = image_facts(os.path.join(d, f"{fam}-{version}.bin"), fam, version)
            images[fam] = {"key": f"{prefix}/{version}/{fam}-{version}.bin", **img}
        m = {"v": 1, "channel": facts["channel"], "bucket": facts["bucket"], "region": facts["region"],
             "version": version, "published": now(), "published_by": facts["published_by"],
             "notes": facts.get("notes", ""), "images": images}
        if facts.get("central"):
            m["central"] = facts["central"]
        with open(out, "w") as f:
            json.dump(m, f, indent=1)
            f.write("\n")
        return 0

    if cmd == "add":
        cat_path, man_path, out = args
        cat = load(cat_path)
        with open(man_path) as f:
            m = json.load(f)
        rel = {k: m[k] for k in ("version", "published", "published_by", "notes", "images")}
        cat["releases"] = [r for r in cat["releases"] if r["version"] != m["version"]] + [rel]
        cat.update({"v": 1, "channel": m["channel"], "bucket": m["bucket"], "region": m["region"], "updated": now()})
        if m.get("central"):
            cat["central"] = m["central"]
        sort_releases(cat)
        keys = ("v", "channel", "bucket", "region", "central", "updated", "releases")
        cat = {k: cat[k] for k in keys if k in cat}
        save(cat, out)
        return 0

    if cmd == "remove":
        cat_path, version, out = args
        cat = load(cat_path)
        before = len(cat["releases"])
        cat["releases"] = [r for r in cat["releases"] if r["version"] != version]
        if len(cat["releases"]) == before:
            die(f"{version} is not published")
        cat["updated"] = now()
        save(cat, out)
        return 0

    if cmd == "has":
        cat_path, version = args
        return 0 if any(r["version"] == version for r in load(cat_path)["releases"]) else 1

    if cmd in ("highest", "bump"):
        cat = load(args[0])
        sort_releases(cat)
        top = next((r["version"] for r in cat["releases"] if _parse(r["version"])), "")
        if cmd == "highest":
            if top:
                print(top)
            return 0
        if not top:
            die("nothing is published yet: give the first version by hand")
        (ma, mi, pa), pre = _parse(top)
        part = args[1]
        # after a pre-release the next patch is its release: 0.4.0-dev → 0.4.0
        nxt = {"patch": (ma, mi, pa if pre else pa + 1), "minor": (ma, mi + 1, 0), "major": (ma + 1, 0, 0)}.get(part)
        if nxt is None:
            die(f"--bump takes patch, minor or major, not '{part}'")
        print("%d.%d.%d" % nxt)
        return 0

    if cmd == "central":   # a DynamoDB get-item / scan answer → {subId, identityId, name}
        with open(args[0]) as f:
            raw = json.load(f)
        items = raw.get("Items") or ([raw["Item"]] if raw.get("Item") else [])
        if len(items) != 1:
            return 1
        i = {k: list(v.values())[0] for k, v in items[0].items()}
        print(json.dumps({"subId": i.get("subId", ""), "identityId": i.get("identityId", ""), "name": i.get("name", "")}))
        return 0

    if cmd == "field":
        print(json.loads(args[0]).get(args[1], ""))
        return 0

    if cmd == "facts":
        out, channel, bucket, region, notes, name, email, arn, host, commit, central = args
        facts = {"channel": channel, "bucket": bucket, "region": region, "notes": notes,
                 "published_by": {"who": name or arn, "email": email, "aws": arn, "host": host, "commit": commit}}
        if central:
            facts["central"] = json.loads(central)
        with open(out, "w") as f:
            json.dump(facts, f)
        return 0

    if cmd == "cmp":
        print(cmp_versions(args[0], args[1]))
        return 0

    if cmd == "list":
        cat = load(args[0])
        if not cat["releases"]:
            print("  (nothing published)")
        for r in cat["releases"]:
            sizes = "  ".join(f"{f} {r['images'][f]['size'] // 1024} KB" for f in FAMILIES if f in r["images"])
            by = r.get("published_by", {}).get("who", "")
            print(f"  {r['version']:<14} {r['published']}  {sizes}  by {by or '?'}  {r.get('notes', '')}")
        return 0

    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
