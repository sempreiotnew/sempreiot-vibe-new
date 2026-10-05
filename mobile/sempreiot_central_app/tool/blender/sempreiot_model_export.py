"""Blender add-on: export a SempreIoT device model straight into the app.

3D Viewport > sidebar (N) > SempreIoT. Pick the product (from the catalogue
in docs/sempreiot-system-reference.md §2.1), check the slug, press
"Export to app": the visible objects of the active collection are written to
mobile/sempreiot_central_app/assets/models/<slug>.glb, the entry in
tool/blender/models.json is created or updated, and tool/blender/factory.sh
<slug> runs in the background (sprites, Dart registry, pubspec, docs).

Model contract: metres, the unit's front faces Blender -Y (numpad 1 = Front
view), its LED marked with the 3D cursor ("Set LED at 3D cursor").
Moving only the LED: "Update LED only" — positions recomputed in seconds,
nothing re-rendered, the .glb untouched.
Install: Edit > Preferences > Add-ons > Install from Disk… this file.
"""
bl_info = {
    "name": "SempreIoT device model export",
    "author": "SempreIoT",
    "version": (1, 0, 0),
    "blender": (4, 2, 0),
    "location": "3D Viewport > Sidebar > SempreIoT",
    "description": "Export a device model to the SempreIoT app and render its Rede 3D sprites",
    "category": "Import-Export",
}

import bpy, os, re, json, subprocess

APP_REL = os.path.join("mobile", "sempreiot_central_app")
ROW = re.compile(r"^\|\s*`0x([0-9A-Fa-f]{4})`\s*\|\s*`([A-Z0-9-]+)`\s*\|\s*([^|]+?)\s*\|\s*(board|node|leaf)\s*\|")
_items = []          # EnumProperty items must stay referenced
_jobs = {}           # slug -> (Popen, log path)


def find_repo(start):
    d = os.path.abspath(start or "")
    while d and d != os.path.dirname(d):
        if os.path.exists(os.path.join(d, APP_REL, "pubspec.yaml")):
            return d
        d = os.path.dirname(d)
    return ""


def repo_root(context):
    st = context.scene.siot_model
    return st.repo if st.repo else find_repo(os.path.dirname(bpy.data.filepath))


def catalogue(repo):
    doc = os.path.join(repo, "docs", "sempreiot-system-reference.md")
    if not os.path.exists(doc):
        return []
    text = open(doc, encoding="utf-8").read()
    start = text.find("### 2.1 Product catalogue")
    end = text.find("\n## ", start)
    rows = []
    for line in text[start:end].splitlines():
        m = ROW.match(line)
        if m:
            name = re.sub(r"\s*\(`[^`]*`\)", "", m.group(3)).strip()
            rows.append((m.group(2), int(m.group(1), 16), m.group(4), name))
    return rows


def product_items(self, context):
    global _items
    rows = catalogue(repo_root(context))
    _items = [(model, f"0x{code:04X} {model}", f"{name} ({fam})") for model, code, fam, name in rows] \
        or [("NONE", "— catalogue not found —", "Save the .blend inside the repository or set the repository folder")]
    return _items


def default_slug(model):
    core = re.sub(r"^SIOT-|-\d+$", "", model or "")
    return core.lower().replace("-", "_")


def on_product(self, context):
    """Pick a product: if it already has a model, load that entry's settings."""
    if not self.product or self.product == "NONE":
        return
    repo = repo_root(context)
    path = os.path.join(repo, APP_REL, "tool", "blender", "models.json") if repo else ""
    entry = None
    if path and os.path.exists(path):
        man = json.load(open(path, encoding="utf-8"))
        entry = next((m for m in man["models"] if self.product in m.get("products", [])), None)
    if entry:
        self["slug"] = entry["slug"]
        self["slug_edited"] = False
        self.family_fallback = entry.get("familyFallback", "none")
        self["hide"] = ", ".join(entry.get("hide", []))
        self["scale"] = float(entry.get("scale", 1.0))
        alarm = entry.get("alarm", {})
        self["alarm_lights"] = ", ".join(alarm.get("lights", []))
        self["alarm_sound"] = bool(alarm.get("sound", False))
        led = entry.get("markers", {}).get("led", {})
        if "point" in led:
            x, y, z = led["point"]
            self["led"] = (x, -z, y)  # glTF -> Blender
            self["use_led"] = True
        else:
            self["use_led"] = False  # an object marker (or none) stays as it is in models.json
        self.status = f"{self.product}: existing model '{entry['slug']}' loaded"
    elif not self.slug_edited:
        self["slug"] = default_slug(self.product)


def on_slug(self, context):
    self["slug_edited"] = True


def dump_manifest(man):
    text = json.dumps(man, indent=2, ensure_ascii=False)
    # Keep arrays of numbers / short names on one line, as the hand-written file has them.
    one_line = lambda m: "[" + ", ".join(x.strip() for x in m.group(1).split(",")) + "]"
    text = re.sub(r"\[\s+([^\[\]{}\"]*?)\s+\]", one_line, text)
    text = re.sub(r'\[\s+((?:"[^",\[\]{}]{0,40}"\s*,?\s*)+?)\s*\]', one_line, text)
    text = re.sub(r'\{\s+("objects": \[[^\]]*\]|"outline": true)\s+\}', r"{\1}", text)
    return text + "\n"


class SIOT_Props(bpy.types.PropertyGroup):
    repo: bpy.props.StringProperty(name="Repository", subtype="DIR_PATH",
                                   description="sempreiot-vibe-new folder; empty = found from this .blend's location")
    product: bpy.props.EnumProperty(name="Product", items=product_items, update=on_product)
    slug: bpy.props.StringProperty(name="Slug", description="assets/models/<slug>.glb — lower_snake_case", update=on_slug)
    slug_edited: bpy.props.BoolProperty(default=False)
    family_fallback: bpy.props.EnumProperty(
        name="Also for", default="none",
        items=[("none", "This product only", ""),
               ("leaf", "Every leaf without a model", "Battery units with no model of their own"),
               ("node", "Every node without a model", "Mains units with no model of their own")])
    hide: bpy.props.StringProperty(name="Hide in sprites", description="Comma-separated object name patterns, e.g. Wire_*, Cable*")
    scale: bpy.props.FloatProperty(name="Size adjust", default=1.0, min=0.5, max=1.5,
                                   description="1.0 = the same visual weight as every other model in the app; nudge only if it still looks off")
    alarm_lights: bpy.props.StringProperty(name="Alarm lights",
                                           description="Objects that light up red in ALARME (comma-separated name patterns), e.g. the siren's lens")
    alarm_sound: bpy.props.BoolProperty(name="Rings in alarm", description="Sound waves come out of its sides in ALARME")
    use_led: bpy.props.BoolProperty(name="LED marker", default=False)
    led: bpy.props.FloatVectorProperty(name="LED (world)", subtype="TRANSLATION", unit="LENGTH")
    status: bpy.props.StringProperty(default="")


def manifest_path(context):
    repo = repo_root(context)
    return os.path.join(repo, APP_REL, "tool", "blender", "models.json") if repo else ""


def led_entry(st):
    x, y, z = st.led
    return {"point": [round(x, 5), round(z, 5), round(-y, 5)], "normal": [0, 0, 1]}  # Blender -> glTF


class SIOT_OT_set_led(bpy.types.Operator):
    bl_idname = "siot.set_led"
    bl_label = "Set LED at 3D cursor"
    bl_description = "The unit's LED is where the 3D cursor is (front of the unit = -Y)"

    def execute(self, context):
        st = context.scene.siot_model
        st.led = context.scene.cursor.location
        st.use_led = True
        return {"FINISHED"}


def _poll_jobs():
    busy = False
    for slug, (proc, log) in list(_jobs.items()):
        rc = proc.poll()
        if rc is None:
            busy = True
            continue
        del _jobs[slug]
        tail = open(log).read().splitlines()
        lines = [l for l in tail if "[factory]" in l]
        msg = f"{slug}: factory OK — app assets, registry, pubspec and docs updated" if rc == 0 else \
              f"{slug}: factory FAILED — " + (lines[-1] if lines else f"see {log}")
        print(msg)
        for sc in bpy.data.scenes:
            if hasattr(sc, "siot_model"):
                sc.siot_model.status = msg
        for w in bpy.context.window_manager.windows:
            for a in w.screen.areas:
                a.tag_redraw()
    return 1.0 if busy else None


def run_factory(app, args, tag):
    log = os.path.join(bpy.app.tempdir or "/tmp", f"siot_factory_{tag}.log")
    proc = subprocess.Popen(["bash", "tool/blender/factory.sh", *args], cwd=app,
                            stdout=open(log, "w"), stderr=subprocess.STDOUT,
                            env={**os.environ, "BLENDER": bpy.app.binary_path})
    _jobs[tag] = (proc, log)
    if not bpy.app.timers.is_registered(_poll_jobs):
        bpy.app.timers.register(_poll_jobs, first_interval=1.0)


class SIOT_OT_export(bpy.types.Operator):
    bl_idname = "siot.export_model"
    bl_label = "Export to app"
    bl_description = "Write assets/models/<slug>.glb from the active collection, register it in models.json and run the factory"

    def execute(self, context):
        st = context.scene.siot_model
        repo = repo_root(context)
        if not repo:
            self.report({"ERROR"}, "Repository not found: save the .blend inside it or set Repository")
            return {"CANCELLED"}
        if st.product in ("", "NONE"):
            self.report({"ERROR"}, "Pick the product")
            return {"CANCELLED"}
        slug = st.slug.strip()
        if not re.fullmatch(r"[a-z][a-z0-9_]*", slug):
            self.report({"ERROR"}, "Slug: lower_snake_case")
            return {"CANCELLED"}
        app = os.path.join(repo, APP_REL)
        objs = [o for o in context.collection.all_objects if o.visible_get() and o.type in {"MESH", "CURVE", "EMPTY", "SURFACE", "META", "FONT"}]
        if not any(o.type != "EMPTY" for o in objs):
            self.report({"ERROR"}, f"Nothing visible in collection '{context.collection.name}'")
            return {"CANCELLED"}
        if context.object and context.object.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
        for o in context.view_layer.objects:
            o.select_set(False)
        for o in objs:
            o.select_set(True)
        glb_rel = f"assets/models/{slug}.glb"
        bpy.ops.export_scene.gltf(filepath=os.path.join(app, glb_rel), export_format="GLB",
                                  use_selection=True, export_apply=True, export_yup=True,
                                  export_cameras=False, export_lights=False, export_animations=False)

        path = os.path.join(app, "tool", "blender", "models.json")
        man = json.load(open(path, encoding="utf-8"))
        entry = next((m for m in man["models"] if m["slug"] == slug), None)
        if entry is None:
            entry = {"slug": slug}
            man["models"].append(entry)
        entry["glb"] = glb_rel
        prods = [p for p in entry.get("products", []) if p != st.product]
        entry["products"] = [st.product] + prods
        for other in man["models"]:  # one model per product
            if other is not entry and st.product in other.get("products", []):
                other["products"].remove(st.product)
        if st.family_fallback == "none":
            entry.pop("familyFallback", None)
        else:
            for other in man["models"]:
                if other is not entry and other.get("familyFallback") == st.family_fallback:
                    other.pop("familyFallback")
            entry["familyFallback"] = st.family_fallback
        hide = [h.strip() for h in st.hide.split(",") if h.strip()]
        if hide:
            entry["hide"] = hide
        else:
            entry.pop("hide", None)
        entry.pop("displaySize", None)
        if abs(st.scale - 1.0) > 1e-3:
            entry["scale"] = round(st.scale, 3)
        else:
            entry.pop("scale", None)
        entry.pop("rim", None)
        entry["alarm"] = {"lights": [h.strip() for h in st.alarm_lights.split(",") if h.strip()],
                          "sound": bool(st.alarm_sound)}
        if st.use_led:
            entry.setdefault("markers", {})["led"] = led_entry(st)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(dump_manifest(man))

        run_factory(app, [slug], slug)
        st.status = f"{slug}: exported {glb_rel}; rendering sprites…"
        self.report({"INFO"}, st.status)
        return {"FINISHED"}


class SIOT_OT_led_only(bpy.types.Operator):
    bl_idname = "siot.led_only"
    bl_label = "Update LED only"
    bl_description = ("Write the LED position for this product's model and recompute where it falls in "
                      "every frame (seconds) — nothing re-rendered, the .glb untouched")

    def execute(self, context):
        st = context.scene.siot_model
        path = manifest_path(context)
        if not path:
            self.report({"ERROR"}, "Repository not found")
            return {"CANCELLED"}
        if not st.use_led:
            self.report({"ERROR"}, "Put the 3D cursor on the LED and press Set LED at 3D cursor first")
            return {"CANCELLED"}
        man = json.load(open(path, encoding="utf-8"))
        entry = next((m for m in man["models"] if m["slug"] == st.slug.strip()), None)
        if entry is None:
            self.report({"ERROR"}, f"No model '{st.slug}' yet — use Export to app the first time")
            return {"CANCELLED"}
        entry.setdefault("markers", {})["led"] = led_entry(st)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(dump_manifest(man))
        run_factory(os.path.dirname(os.path.dirname(os.path.dirname(path))), [entry["slug"], "--markers"], entry["slug"])
        st.status = f"{entry['slug']}: LED moved; updating its positions…"
        self.report({"INFO"}, st.status)
        return {"FINISHED"}


class SIOT_OT_factory_all(bpy.types.Operator):
    bl_idname = "siot.factory_all"
    bl_label = "Rebuild changed models"
    bl_description = "Run tool/blender/factory.sh: re-render every model whose .glb or entry changed"

    def execute(self, context):
        repo = repo_root(context)
        if not repo:
            self.report({"ERROR"}, "Repository not found")
            return {"CANCELLED"}
        run_factory(os.path.join(repo, APP_REL), [], "all")
        context.scene.siot_model.status = "factory running…"
        return {"FINISHED"}


class SIOT_PT_panel(bpy.types.Panel):
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "SempreIoT"
    bl_label = "Device model → app"

    def draw(self, context):
        st = context.scene.siot_model
        col = self.layout.column()
        col.prop(st, "repo")
        col.label(text=f"Exports collection: {context.collection.name}", icon="OUTLINER_COLLECTION")
        col.prop(st, "product")
        col.prop(st, "slug")
        col.prop(st, "family_fallback")
        col.prop(st, "hide")
        col.prop(st, "scale")
        col.prop(st, "alarm_lights")
        col.prop(st, "alarm_sound")
        row = col.row(align=True)
        row.prop(st, "use_led", text="")
        sub = row.row(); sub.enabled = st.use_led; sub.prop(st, "led", text="")
        row = col.row(align=True)
        row.operator("siot.set_led", icon="PIVOT_CURSOR")
        row.operator("siot.led_only", icon="LIGHT")
        col.separator()
        col.operator("siot.export_model", icon="EXPORT")
        col.operator("siot.factory_all", icon="FILE_REFRESH")
        if _jobs:
            col.label(text="Factory running…", icon="SORTTIME")
        if st.status:
            for i, part in enumerate([st.status[k:k + 48] for k in range(0, len(st.status), 48)]):
                col.label(text=part, icon="INFO" if i == 0 else "BLANK1")


classes = (SIOT_Props, SIOT_OT_set_led, SIOT_OT_led_only, SIOT_OT_export, SIOT_OT_factory_all, SIOT_PT_panel)


def register():
    for c in classes:
        bpy.utils.register_class(c)
    bpy.types.Scene.siot_model = bpy.props.PointerProperty(type=SIOT_Props)


def unregister():
    if bpy.app.timers.is_registered(_poll_jobs):
        bpy.app.timers.unregister(_poll_jobs)
    del bpy.types.Scene.siot_model
    for c in reversed(classes):
        bpy.utils.unregister_class(c)


if __name__ == "__main__":
    register()
