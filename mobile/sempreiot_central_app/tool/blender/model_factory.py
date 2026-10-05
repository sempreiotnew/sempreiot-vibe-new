"""SempreIoT model factory — a device .glb in, everything the app needs out.

    tool/blender/factory.sh [slug ...] [--force] [--markers] [--codegen]
    (= blender -b --factory-startup --python tool/blender/model_factory.py -- ...)

For every model in tool/blender/models.json (or the ones named):

  images  — when the .glb or what changes the pictures changed (or --force):
     <slug>_atlas.png       the model from every yaw x pitch of the Rede 3D camera
     <slug>_spin.png        one turn at a fixed tilt, fine steps (Dispositivos)
     <slug>_glow.png        the "alarm lights" objects alone, same frames as the
     <slug>_spin_glow.png   atlas / spin (only when the model has alarm lights)
  markers — when only a marker (e.g. the LED) moved, or --markers: just the
     positions, no rendering (seconds)
     <slug>_frames.json     sizes, angles, bodyFraction, every marker per frame,
                            alarm flags, fingerprints
  code    — always, for all models (cheap):
     lib/.../network_3d/device_models.g.dart   product code -> model
     pubspec.yaml block between the device-models markers
     docs/sempreiot-system-reference.md §2.1.1 between the device-models markers

Products are model strings from the catalogue table in
docs/sempreiot-system-reference.md §2.1; the factory refuses one that is not
there or not in SafrProduct.catalogue (safr_product.dart). See README.md.
"""
import bpy, sys, os, json, math, hashlib, fnmatch, re, time
import numpy as np
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view

FACTORY_VERSION = 2
HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.normpath(os.path.join(HERE, "..", ".."))
REPO = os.path.normpath(os.path.join(APP, "..", ".."))
MANIFEST = os.path.join(HERE, "models.json")
DOC = os.path.join(REPO, "docs", "sempreiot-system-reference.md")
PRODUCT_DART = os.path.join(APP, "lib/features/central/domain/safr/safr_product.dart")
GEN_DART = os.path.join(APP, "lib/features/central/presentation/widgets/network_3d/device_models.g.dart")
PUBSPEC = os.path.join(APP, "pubspec.yaml")
FAMILIES = ("board", "node", "leaf")


def log(*a):
    print("[factory]", *a, flush=True)


def fail(msg):
    print("[factory] ERROR:", msg, flush=True)
    sys.exit(1)


# ── Catalogue and manifest ──────────────────────────────────────────────────

ROW = re.compile(r"^\|\s*`0x([0-9A-Fa-f]{4})`\s*\|\s*`([A-Z0-9-]+)`\s*\|\s*([^|]+?)\s*\|\s*(board|node|leaf)\s*\|")


def read_catalogue():
    """model string -> {code, family, name} from the §2.1 table."""
    text = open(DOC, encoding="utf-8").read()
    start = text.find("### 2.1 Product catalogue")
    if start < 0:
        fail("docs/sempreiot-system-reference.md has no '### 2.1 Product catalogue'")
    end = text.find("\n## ", start)
    cat = {}
    for line in text[start:end].splitlines():
        m = ROW.match(line)
        if m:
            name = re.sub(r"\s*\(`[^`]*`\)", "", m.group(3)).strip()
            cat[m.group(2)] = {"code": int(m.group(1), 16), "family": m.group(4), "name": name}
    if not cat:
        fail("no product rows found in §2.1")
    dart = open(PRODUCT_DART, encoding="utf-8").read()
    dart_codes = {int(c, 16): m for c, m in re.findall(r"SafrProduct\._\(\s*0x([0-9A-Fa-f]{4}),\s*'([A-Z0-9-]+)'", dart)}
    return cat, dart_codes


def load_manifest(cat, dart_codes):
    man = json.load(open(MANIFEST, encoding="utf-8"))
    d = man["defaults"]
    seen_products, seen_fallback, slugs = {}, {}, set()
    for m in man["models"]:
        s = m["slug"]
        if not re.fullmatch(r"[a-z][a-z0-9_]*", s):
            fail(f"slug '{s}': lower_snake_case only")
        if s in slugs:
            fail(f"slug '{s}' twice")
        slugs.add(s)
        if not os.path.exists(os.path.join(APP, m["glb"])):
            fail(f"{s}: {m['glb']} not found")
        if not m.get("products") and not m.get("familyFallback"):
            fail(f"{s}: needs products and/or familyFallback")
        for p in m.get("products", []):
            if p not in cat:
                fail(f"{s}: product '{p}' is not in §2.1. Known: " + ", ".join(sorted(cat)))
            code = cat[p]["code"]
            if dart_codes.get(code) != p:
                fail(f"{s}: {p} (0x{code:04X}) is in §2.1 but not in SafrProduct.catalogue — add it there first")
            if p in seen_products:
                fail(f"{p} is mapped to both '{seen_products[p]}' and '{s}'")
            seen_products[p] = s
        fb = m.get("familyFallback")
        if fb:
            if fb not in FAMILIES:
                fail(f"{s}: familyFallback must be one of {FAMILIES}")
            if fb in seen_fallback:
                fail(f"familyFallback '{fb}' on both '{seen_fallback[fb]}' and '{s}'")
            seen_fallback[fb] = s
        for k, v in d.items():
            m.setdefault(k, v)
        m.setdefault("hide", [])
        m.setdefault("markers", {})
        m.setdefault("alarm", {})
        m["alarm"].setdefault("lights", [])
        m["alarm"].setdefault("sound", False)
        if "rim" in m:
            log(f"{s}: 'rim' is no longer used (the model is drawn as it is) — remove it from models.json")
    return man


def has_glow(m):
    return bool(m["alarm"]["lights"])


def out_paths(m):
    """Every asset the app bundles for this model (frames.json last)."""
    base = os.path.join(APP, "assets", "models", m["slug"])
    paths = {"atlas": base + "_atlas.png", "spin": base + "_spin.png"}
    if has_glow(m):
        paths["glow"] = base + "_glow.png"
        paths["spinGlow"] = base + "_spin_glow.png"
    paths["frames"] = base + "_frames.json"
    return paths


def _hash(m, *parts):
    h = hashlib.sha1()
    h.update(open(os.path.join(APP, m["glb"]), "rb").read())
    for p in parts:
        h.update(json.dumps(p, sort_keys=True).encode())
    h.update(str(FACTORY_VERSION).encode())
    return h.hexdigest()[:16]


def framing(m):
    """What decides where the camera looks — shared by images and markers."""
    return {k: m.get(k) for k in ("hide", "orthoScale", "bodyFraction", "size", "yaws", "pitches", "spin")}


def images_fp(m):
    return _hash(m, framing(m), m["alarm"]["lights"])


def markers_fp(m):
    return _hash(m, framing(m), m["markers"])


def staleness(m):
    """'images' (render everything), 'markers' (positions only) or None."""
    paths = out_paths(m)
    if not all(os.path.exists(p) for p in paths.values()):
        return "images"
    try:
        src = json.load(open(paths["frames"])).get("source", {})
    except Exception:
        return "images"
    if src.get("images") != images_fp(m):
        return "images"
    if src.get("markers") != markers_fp(m):
        return "markers"
    return None


# ── Scene ───────────────────────────────────────────────────────────────────

def gltf_to_blender(v):
    # glTF (x, y up, z toward viewer) -> Blender (x, -z, y)
    return Vector((v[0], -v[2], v[1]))


class Scene:
    """The .glb in an empty scene, framed and lit like the original detector sprites."""

    def __init__(self, m):
        self.m = m
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.import_scene.gltf(filepath=os.path.join(APP, m["glb"]))
        sc = self.sc = bpy.context.scene
        meshes = [o for o in sc.objects if o.type == "MESH"]
        hidden = [o for o in meshes if any(fnmatch.fnmatch(o.name, pat) for pat in m["hide"])]
        for o in hidden:
            o.hide_render = True
        self.visible = [o for o in meshes if o not in hidden]
        if not self.visible:
            fail(f"{m['slug']}: every mesh is hidden")
        bpy.context.view_layer.update()
        pts = [o.matrix_world @ v.co for o in self.visible for v in o.data.vertices]
        lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
        hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
        self.centre, dims = (lo + hi) / 2, hi - lo
        max_dim = max(dims)
        # The frame fits the largest side at bodyFraction, and never less than the
        # bounding box's diagonal, so a boxy unit seen corner-on is not clipped.
        self.ortho = m.get("orthoScale") or max(max_dim / m["bodyFraction"], dims.length * 1.02)
        self.body_fraction = max_dim / self.ortho
        self.dims = [dims.x, dims.z, dims.y]  # glTF order

        try:
            sc.render.engine = "BLENDER_EEVEE"
        except TypeError:
            sc.render.engine = "BLENDER_EEVEE_NEXT"
        sc.render.resolution_x = sc.render.resolution_y = m["size"]
        sc.render.film_transparent = True
        sc.render.image_settings.file_format = "PNG"
        sc.render.image_settings.color_mode = "RGBA"
        sc.view_settings.view_transform = "AgX"
        try:
            sc.view_settings.look = "AgX - Medium High Contrast"
        except TypeError:
            pass
        world = bpy.data.worlds.new("W"); sc.world = world
        world.use_nodes = True
        world.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.58, 0.62, 1)
        world.node_tree.nodes["Background"].inputs[1].default_value = 0.35

        target = bpy.data.objects.new("Target", None); sc.collection.objects.link(target)
        target.location = self.centre
        k = max_dim / 0.1  # the detector (0.1 m) is the reference the light rig was tuned on

        def area(name, off, energy, size):
            l = bpy.data.lights.new(name, "AREA"); l.energy = energy * k * k; l.size = size * k
            o = bpy.data.objects.new(name, l); sc.collection.objects.link(o)
            o.location = self.centre + Vector(off) * k
            c = o.constraints.new("TRACK_TO"); c.target = target
            c.track_axis = "TRACK_NEGATIVE_Z"; c.up_axis = "UP_Y"
        # Key from top-left-front (the app's light), fill right, rim from behind.
        area("Key", (-0.25, -0.30, 0.35), 3.0, 0.25)
        area("Fill", (0.30, -0.25, 0.05), 0.8, 0.3)
        area("Back", (0.05, 0.35, 0.25), 1.5, 0.2)

        cd = bpy.data.cameras.new("Cam"); cd.type = "ORTHO"; cd.ortho_scale = self.ortho
        cd.clip_start = 0.001; cd.clip_end = 100
        cam = self.cam = bpy.data.objects.new("Cam", cd); sc.collection.objects.link(cam); sc.camera = cam
        tc = cam.constraints.new("TRACK_TO"); tc.target = target
        tc.track_axis = "TRACK_NEGATIVE_Z"; tc.up_axis = "UP_Y"
        self.dist = max(0.5, max_dim * 5)

        self.markers = {}
        for name, mk in m["markers"].items():
            if "object" in mk:
                o = sc.objects.get(mk["object"])
                if o is None or o.type != "MESH":
                    fail(f"{m['slug']}: marker '{name}' object '{mk['object']}' not in the glb")
                vs = [o.matrix_world @ v.co for v in o.data.vertices]
                pos = sum(vs, Vector()) / len(vs)
            elif "point" in mk:
                pos = gltf_to_blender(mk["point"])
            else:
                fail(f"{m['slug']}: marker '{name}' needs 'object' or 'point'")
            self.markers[name] = (pos, gltf_to_blender(mk.get("normal", [0, 0, 1])).normalized())

        self.lights = [o for o in self.visible if any(fnmatch.fnmatch(o.name, p) for p in m["alarm"]["lights"])]
        if m["alarm"]["lights"] and not self.lights:
            fail(f"{m['slug']}: alarm lights {m['alarm']['lights']} match no visible object in the glb")

    def place(self, yaw, pitch):
        y, p = math.radians(yaw), math.radians(pitch)
        self.cam.location = self.centre + self.dist * Vector(
            (math.cos(p) * math.sin(y), -math.cos(p) * math.cos(y), math.sin(p)))
        bpy.context.view_layer.update()

    def marker_frames(self, angles):
        out = {n: [] for n in self.markers}
        for pitch, yaw in angles:
            self.place(yaw, pitch)
            for n, (pos, nrm) in self.markers.items():
                co = world_to_camera_view(self.sc, self.cam, pos)
                vis = nrm.dot((self.cam.location - pos).normalized()) > 0.05
                out[n].append([round(co.x, 4), round(1 - co.y, 4), 1 if vis else 0])
        return out

    def render(self, angles, folder, prefix):
        files = []
        for i, (pitch, yaw) in enumerate(angles):
            self.place(yaw, pitch)
            f = os.path.join(folder, f"{prefix}{i:03d}.png")
            self.sc.render.filepath = f
            bpy.ops.render.render(write_still=True)
            files.append(f)
        return files

    def lights_only(self):
        """Alarm lights in white; every other visible object held out (so a
        light hidden behind the cover stays hidden)."""
        mat = bpy.data.materials.new("Glow"); mat.use_nodes = True
        nt = mat.node_tree; nt.nodes.clear()
        e = nt.nodes.new("ShaderNodeEmission"); e.inputs[0].default_value = (1, 1, 1, 1); e.inputs[1].default_value = 1
        o = nt.nodes.new("ShaderNodeOutputMaterial"); nt.links.new(e.outputs[0], o.inputs[0])
        for ob in self.visible:
            if ob in self.lights:
                if not ob.data.materials:
                    ob.data.materials.append(mat)
                for i in range(len(ob.data.materials)):
                    ob.data.materials[i] = mat
            else:
                ob.is_holdout = True


def map_angles(m):
    return [(p, y) for p in m["pitches"] for y in m["yaws"]]


def spin_yaws(m):
    return list(range(0, 360, int(m["spin"]["step"])))


def spin_angles(m):
    return [(m["spin"]["pitch"], y) for y in spin_yaws(m)]


# ── Images ──────────────────────────────────────────────────────────────────

def load_px(path):
    im = bpy.data.images.load(path)
    w, h = im.size
    px = np.array(im.pixels[:], dtype=np.float32).reshape(h, w, 4)
    bpy.data.images.remove(im)
    return px


def pack(files, cols, out):
    frames = [load_px(f) for f in files]
    h, w = frames[0].shape[:2]
    rows = (len(frames) + cols - 1) // cols
    sheet = np.zeros((rows * h, cols * w, 4), dtype=np.float32)
    for i, px in enumerate(frames):
        r, c = i // cols, i % cols
        y0 = (rows - 1 - r) * h  # Blender images are bottom-up
        sheet[y0:y0 + h, c * w:(c + 1) * w] = px
    res = bpy.data.images.new("sheet", cols * w, rows * h, alpha=True)
    res.pixels[:] = sheet.ravel()
    res.filepath_raw = out; res.file_format = "PNG"; res.save()
    bpy.data.images.remove(res)
    log("wrote", os.path.relpath(out, APP), f"{cols * w}x{rows * h}")


def write_frames(m, scene, prev=None):
    paths = out_paths(m)
    data = {
        "factory": FACTORY_VERSION,
        "source": {"images": (prev or {}).get("source", {}).get("images") if prev else images_fp(m),
                   "markers": markers_fp(m)},
        "slug": m["slug"],
        "size": m["size"],
        "yaws": m["yaws"],
        "pitches": m["pitches"],
        "bodyFraction": round(scene.body_fraction, 4),
        "orthoScale": round(scene.ortho, 5),
        "dims": [round(x, 4) for x in scene.dims],
        "markers": scene.marker_frames(map_angles(m)),
        "spin": {
            "pitch": m["spin"]["pitch"],
            "yaws": spin_yaws(m),
            "cols": m["spin"]["cols"],
            "markers": scene.marker_frames(spin_angles(m)),
        },
        "alarm": {"lights": has_glow(m), "sound": bool(m["alarm"]["sound"])},
    }
    with open(paths["frames"], "w") as fh:
        json.dump(data, fh, separators=(",", ":"))


def build_images(m):
    t0 = time.time()
    slug = m["slug"]
    maps, spins = map_angles(m), spin_angles(m)
    log(f"{slug}: rendering {len(maps)} + {len(spins)} frames"
        f"{' (and the alarm lights)' if has_glow(m) else ''} from {m['glb']}")
    scene = Scene(m)
    tmp = os.path.join(bpy.app.tempdir or "/tmp", f"siot_factory_{slug}")
    os.makedirs(tmp, exist_ok=True)
    paths = out_paths(m)
    pack(scene.render(maps, tmp, "c"), len(m["yaws"]), paths["atlas"])
    pack(scene.render(spins, tmp, "s"), int(m["spin"]["cols"]), paths["spin"])
    if has_glow(m):
        scene.lights_only()
        pack(scene.render(maps, tmp, "g"), len(m["yaws"]), paths["glow"])
        pack(scene.render(spins, tmp, "h"), int(m["spin"]["cols"]), paths["spinGlow"])
    write_frames(m, scene)
    log(f"{slug}: done in {time.time() - t0:.0f} s (bodyFraction {scene.body_fraction:.3f})")


def build_markers(m):
    t0 = time.time()
    prev = json.load(open(out_paths(m)["frames"]))
    write_frames(m, Scene(m), prev)
    log(f"{m['slug']}: markers updated in {time.time() - t0:.1f} s (no rendering)")


# ── Code generation ─────────────────────────────────────────────────────────

def write_if_changed(path, text):
    old = open(path, encoding="utf-8").read() if os.path.exists(path) else None
    if old != text:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        log("updated", os.path.relpath(path, REPO))


def replace_block(text, begin, end, body, what):
    i, j = text.find(begin), text.find(end)
    if i < 0 or j < 0 or j < i:
        fail(f"{what}: markers '{begin}' / '{end}' not found")
    i = text.find("\n", i) + 1
    j = text.rfind("\n", 0, j) + 1
    return text[:i] + body + text[j:]


def codegen(man, cat):
    models = man["models"]
    rel = lambda p: os.path.relpath(p, APP)
    lines = [
        "// GENERATED by tool/blender/model_factory.py from tool/blender/models.json",
        "// and the product catalogue (docs/sempreiot-system-reference.md §2.1).",
        "// Do not edit: change the manifest and run tool/blender/factory.sh.",
        "",
        "import '../../../domain/safr/safr_product.dart';",
        "import 'device_model_sprites.dart';",
        "",
        "/// Every device model the app can draw.",
        "const deviceModelSpecs = <DeviceModelSpec>[",
    ]
    for m in models:
        p = out_paths(m)
        codes = ", ".join(f"0x{cat[x]['code']:04X}" for x in m.get("products", []))
        names = ", ".join(m.get("products", []))
        fb = m.get("familyFallback")
        lines += [
            "  DeviceModelSpec(",
            f"    slug: '{m['slug']}',",
            f"    productCodes: [{codes}],{' // ' + names if names else ''}",
            f"    familyFallback: {'SafrProductFamily.' + fb if fb else 'null'},",
            f"    atlas: '{rel(p['atlas'])}',",
            f"    spin: '{rel(p['spin'])}',",
            f"    glow: {repr(rel(p['glow'])) if 'glow' in p else 'null'},",
            f"    spinGlow: {repr(rel(p['spinGlow'])) if 'spinGlow' in p else 'null'},",
            f"    frames: '{rel(p['frames'])}',",
            f"    displaySize: {float(m['displaySize'])},",
            f"    alarmSound: {'true' if m['alarm']['sound'] else 'false'},",
            "  ),",
        ]
    lines += ["];", ""]
    write_if_changed(GEN_DART, "\n".join(lines).replace("'", "'"))

    body = "".join(f"    - {rel(x)}\n" for m in models for x in out_paths(m).values())
    ps = open(PUBSPEC, encoding="utf-8").read()
    write_if_changed(PUBSPEC, replace_block(ps, "# >>> device-models", "# <<< device-models", body, "pubspec.yaml"))

    rows = ["| Product(s) | 3D model (source) | In alarm | Also drawn for |", "|---|---|---|---|"]
    for m in models:
        prods = "<br>".join(f"`0x{cat[x]['code']:04X}` `{x}` {cat[x]['name']}" for x in m.get("products", [])) or "—"
        fb = m.get("familyFallback")
        also = f"every **{fb}** unit whose product has no model of its own or is not reported" if fb else "—"
        alarm = ", ".join(filter(None, ["red lights" if has_glow(m) else "", "sound waves" if m["alarm"]["sound"] else ""])) or "—"
        rows.append(f"| {prods} | `{m['slug']}` (`mobile/sempreiot_central_app/{m['glb']}`) | {alarm} | {also} |")
    doc = open(DOC, encoding="utf-8").read()
    write_if_changed(DOC, replace_block(doc, "<!-- device-models:begin", "<!-- device-models:end", "\n".join(rows) + "\n", "system reference"))


# ── Main ────────────────────────────────────────────────────────────────────

def main():
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    force = "--force" in args
    only_markers = "--markers" in args
    only_codegen = "--codegen" in args
    names = [a for a in args if not a.startswith("--")]
    cat, dart_codes = read_catalogue()
    man = load_manifest(cat, dart_codes)
    by_slug = {m["slug"]: m for m in man["models"]}
    for n in names:
        if n not in by_slug:
            fail(f"no model '{n}' in models.json (have: {', '.join(by_slug)})")
    if not only_codegen:
        chosen = [by_slug[n] for n in names] if names else man["models"]
        did = False
        for m in chosen:
            need = staleness(m)
            if force:
                need = "images"
            elif only_markers and need != "images":
                need = "markers"
            elif only_markers and need == "images":
                fail(f"{m['slug']}: the images are out of date too (new .glb or framing) — run without --markers")
            if need == "images":
                build_images(m); did = True
            elif need == "markers":
                build_markers(m); did = True
        if not did:
            log("every model is up to date (use --force to re-render)")
    codegen(man, cat)
    log("ok")


main()
