"""Renders smoke_detector.glb into sprites for the Rede 3D screen.

  blender -b --python render.py -- <out_dir> <preview|atlas>

preview: 8 angles, colour only, then a contact sheet.
atlas:   YAWS x PITCHES frames -> colour atlas + rim-mask atlas + JSON
         (per frame: the LED's position in the frame and whether it faces
         the camera).

Angles follow the app's OrbitCamera: yaw turns around the vertical, pitch
> 0 = camera above looking down. App axes (x right, y up, z toward viewer)
map to Blender (x, -z... ) as: app x = B x, app y = B z, app z = -B y.
"""
import bpy, sys, os, json, math
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view

GLB = "/Users/tallesrocha/Desktop/sempreiot-vibe-new/mobile/sempreiot_central_app/assets/models/smoke_detector.glb"
out, mode = sys.argv[sys.argv.index("--") + 1:][:2]
os.makedirs(out, exist_ok=True)
SIZE = 160
YAWS = list(range(0, 360, 15))            # 24
PITCHES = [-15, 0, 15, 30, 45, 60, 75]    # 7  (app pitch range ≈ −14°..69°)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=GLB)
sc = bpy.context.scene
body, led, rim = (bpy.data.objects[n] for n in ("Body", "LED", "Rim"))

# Engine: EEVEE if available (fast), else Cycles.
try:
    sc.render.engine = "BLENDER_EEVEE"
except TypeError:
    sc.render.engine = "BLENDER_EEVEE_NEXT"
sc.render.resolution_x = sc.render.resolution_y = SIZE
sc.render.film_transparent = True
sc.render.image_settings.file_format = "PNG"
sc.render.image_settings.color_mode = "RGBA"
sc.view_settings.view_transform = "AgX"
try:
    sc.view_settings.look = "AgX - Medium High Contrast"
except TypeError:
    pass

# World: soft grey ambient.
world = bpy.data.worlds.new("W"); sc.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.58, 0.62, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.35

def area(name, loc, energy, size):
    l = bpy.data.lights.new(name, "AREA"); l.energy = energy; l.size = size
    o = bpy.data.objects.new(name, l); sc.collection.objects.link(o)
    o.location = loc
    c = o.constraints.new("TRACK_TO"); c.target = body
    c.track_axis = "TRACK_NEGATIVE_Z"; c.up_axis = "UP_Y"
# Key from top-left-front (the app's light), fill right, rim from behind.
area("Key", (-0.25, -0.30, 0.35), 3.0, 0.25)
area("Fill", (0.30, -0.25, 0.05), 0.8, 0.3)
area("Back", (0.05, 0.35, 0.25), 1.5, 0.2)

cam_data = bpy.data.cameras.new("Cam"); cam_data.type = "ORTHO"; cam_data.ortho_scale = 0.125
cam = bpy.data.objects.new("Cam", cam_data); sc.collection.objects.link(cam); sc.camera = cam
tc = cam.constraints.new("TRACK_TO"); tc.target = body
tc.track_axis = "TRACK_NEGATIVE_Z"; tc.up_axis = "UP_Y"

def place(yaw, pitch):
    y, p = math.radians(yaw), math.radians(pitch)
    d = 0.5
    # app dir (cos p sin y, sin p, cos p cos y) -> Blender (x, -z_app, y_app)
    cam.location = (d * math.cos(p) * math.sin(y), -d * math.cos(p) * math.cos(y), d * math.sin(p))
    bpy.context.view_layer.update()

# The LED lens's real centre (its object origin may sit at the body centre).
_lv = [led.matrix_world @ v.co for v in led.data.vertices]
LED_C = sum(_lv, Vector()) / len(_lv)

def led_info():
    co = world_to_camera_view(sc, cam, LED_C)
    # Faces the camera if the LED's outward normal (from the body centre,
    # on the face side = Blender −Y) points toward the camera.
    face_n = Vector((0, -1, 0))
    to_cam = (cam.location - LED_C).normalized()
    return round(co.x, 4), round(1 - co.y, 4), face_n.dot(to_cam) > 0.05

def render(path):
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)

if mode == "json":  # LED positions only, no rendering
    frames = []
    for pitch in PITCHES:
        for yaw in YAWS:
            place(yaw, pitch)
            lx, ly, lv = led_info()
            frames.append({"yaw": yaw, "pitch": pitch, "led": [lx, ly], "ledVisible": lv})
    json.dump({"size": SIZE, "yaws": YAWS, "pitches": PITCHES, "frames": frames},
              open(os.path.join(out, "frames.json"), "w"), indent=1)
    print("LED_C", tuple(round(x, 4) for x in LED_C), "frames", len(frames))
    sys.exit(0)

if mode == "preview":
    for i, (yaw, pitch) in enumerate([(0, 0), (0, 30), (35, 20), (90, 15), (160, 20), (220, 30), (300, 45), (0, 75)]):
        place(yaw, pitch)
        render(os.path.join(out, f"p{i}_{yaw}_{pitch}.png"))
    sys.exit(0)

# ── Atlas ───────────────────────────────────────────────────────────────
frames = []
rim_mat = rim.data.materials[0]
for pi, pitch in enumerate(PITCHES):
    for yi, yaw in enumerate(YAWS):
        place(yaw, pitch)
        # Colour frame.
        render(os.path.join(out, "c", f"{pi:02d}_{yi:02d}.png"))
        lx, ly, lv = led_info()
        frames.append({"yaw": yaw, "pitch": pitch, "led": [lx, ly], "ledVisible": lv})

# Rim mask: everything black holdout except the rim, rendered white.
for o in (body, led):
    o.is_holdout = True
emit = bpy.data.materials.new("RimMask"); emit.use_nodes = True
nt = emit.node_tree; nt.nodes.clear()
e = nt.nodes.new("ShaderNodeEmission"); e.inputs[0].default_value = (1, 1, 1, 1); e.inputs[1].default_value = 1
o_ = nt.nodes.new("ShaderNodeOutputMaterial"); nt.links.new(e.outputs[0], o_.inputs[0])
rim.data.materials[0] = emit
for pi, pitch in enumerate(PITCHES):
    for yi, yaw in enumerate(YAWS):
        place(yaw, pitch)
        render(os.path.join(out, "r", f"{pi:02d}_{yi:02d}.png"))

json.dump({"size": SIZE, "yaws": YAWS, "pitches": PITCHES, "frames": frames},
          open(os.path.join(out, "frames.json"), "w"), indent=1)
print("ATLAS FRAMES", len(frames))
