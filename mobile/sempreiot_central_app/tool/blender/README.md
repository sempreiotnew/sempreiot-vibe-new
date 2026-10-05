# Device model factory

**A `.glb` in → everything the app needs to draw that product as its 3D model out** — on the Rede 3D
map, on the Dispositivos list (turning on itself) and on each unit's Dispositivo screen.

Every product in the catalogue (`docs/sempreiot-system-reference.md` §2.1 — siren, push-button
station, smoke detector, …) can have a 3D model. You make the model in Blender and press one
button; the factory renders it, wires it to the right product code, registers the assets and
updates the docs. **No Dart, `pubspec.yaml` or documentation is edited by hand.**

- [How it works](#how-it-works)
- [Adding a model for a new product](#adding-a-model-for-a-new-product) ← start here
- [Moving the LED](#moving-the-led) ← seconds, no re-render
- [Alarm lights and sound](#alarm-lights-and-sound)
- [Sizing: equal visual weight](#sizing-equal-visual-weight)
- [Updating an existing model](#updating-an-existing-model)
- [The model contract](#the-model-contract-what-the-glb-must-look-like)
- [`models.json` reference](#modelsjson-reference)
- [What the factory checks](#what-the-factory-checks-and-the-errors-it-gives)
- [Inside the factory](#inside-the-factory)
- [How the app uses it](#how-the-app-uses-it)
- [Files](#files)

---

## How it works

The tablet has no 3D engine. Each model is **pre-rendered** in Blender and packed into images:

- the **atlas** — every angle the Rede 3D camera can take (24 turns × 7 tilts = 168 frames);
- the **spin** — one full turn at 15° above, in 5° steps (72 frames), for the spinning Dispositivos
  cards and the Dispositivo header;
- for a model with **alarm lights** (the siren's lens), the same frames again with only those parts, in
  white — the app turns them red in ALARME.

At runtime the app picks the frame for the angle it needs (blending two spin frames while it turns, so
the spin is smooth), draws it **as rendered — no outline**, and puts the unit's **LED dot** on top, where
the model's LED is in that frame.

```
  Blender                         tool/blender/                          app
 ─────────                       ───────────────                       ─────
 your model ──Export to app──▶  assets/models/<slug>.glb
 (one collection)                models.json  ◀── product (from §2.1), LED, alarm lights
                                     │
                              factory.sh / model_factory.py  (Blender, headless)
                                     │
             ┌───────────────────────┼─────────────────────────────┬──────────────────────────┐
             ▼                       ▼                             ▼                          ▼
  <slug>_atlas.png          device_models.g.dart          pubspec.yaml block        system reference
  <slug>_spin.png           (product code → model)        (assets)                  §2.1.1 (table)
  <slug>_glow.png, _spin_glow.png (alarm lights)
  <slug>_frames.json  (LED per frame, sizes, fingerprints)
             └────────────────────────┴──────────────▶  every unit whose product code has a model:
                                                         Rede 3D (Model3dChip), Dispositivos and
                                                         Dispositivo (DeviceModelAvatar)
```

The link between a model and a device type is the **model string** of the product catalogue
(`SIOT-SIREN-01`). The factory reads the catalogue table in §2.1 to turn it into the 16-bit PRODUCT
code the unit reports on the wire (`0x0201`), and that code is what the app looks up.

**The LED is not in the images.** Blender only says *where* the LED is; the light itself is the app's
`DeviceLedDot`, drawn live on top in the LED language (same colour, duration and order as the real unit),
so it blinks, pulses and changes colour, and it is always visible — on the far side of the model it is
only slightly dimmed.

---

## Adding a model for a new product

### Step 0 — is the product in the catalogue?

Open `docs/sempreiot-system-reference.md` §2.1.

- **It is there** (e.g. `0x0202 SIOT-PBS-01` push-button station) → go to step 1.
- **It is not** → the product has to exist before its model. Follow the §2.1 rules:
  1. Add the row to the §2.1 table with the **next free code of its family** (`0x02xx` mains unit,
     `0x03xx` battery unit). A code is a contract: never reused, never renumbered.
  2. Add the same code, model string and pt-BR label to `SafrProduct.catalogue` in
     `lib/features/central/domain/safr/safr_product.dart`.
  3. The firmware side (pin map entry in `tools/pinmap/pinmap.yaml`, feature component) follows the
     product rules in §2.1 — the 3D model does not need it, but the unit must report the code for the
     app to show the model.

  The factory refuses a product that is missing from either place (see
  [checks](#what-the-factory-checks-and-the-errors-it-gives)).

### Step 1 — model it in Blender

Follow the [model contract](#the-model-contract-what-the-glb-must-look-like): real size in **metres**,
the unit's **front facing −Y** (numpad 1, Front view, shows the face you see when it is on the wall),
every object of the unit in **one collection**. Save the `.blend` inside the repo, next to the others:
`assets/models/<slug>.blend` (it is the source; it is not bundled in the app).

Anything that should not appear in the app — cables, labels — can stay in the model and be left out by
name (step 2).

### Step 2 — export from the SempreIoT panel

The add-on is installed on the dev Mac. Elsewhere: Edit › Preferences › Add-ons › Install from Disk… →
`tool/blender/sempreiot_model_export.py`.

In the 3D Viewport press **N** → tab **SempreIoT**:

| Field | What to put |
|---|---|
| *Exports collection* | the active collection — click your model's collection in the Outliner first |
| **Product** | pick it from the list (read live from §2.1). If it already has a model, that model's settings load |
| **Slug** | file name, lower_snake_case — proposed from the model string (`SIOT-PBS-01` → `pbs`); rename if you like (`push_button`) |
| **Also for** | normally *This product only*. *Every leaf/node without a model* makes it the stand-in for units of that family that have no model of their own (today the smoke detector is the leaf stand-in) |
| **Hide in sprites** | object name patterns left out of the renders, comma separated: `Wire_*, Tip_*` |
| **Size adjust** | leave at **1.0**: every model is drawn with the same visual weight automatically ([sizing](#sizing-equal-visual-weight)). Nudge (0.5–1.5) only if one still looks off |
| **Alarm lights** | objects that light up red in ALARME, e.g. a siren's lens: `SIREN_Lens, SIREN_Lens_Boss`. Empty = none |
| **Rings in alarm** | sound waves come out of its sides in ALARME (sounders) |
| **LED** | put the 3D cursor on the unit's status LED (Shift + right-click on the surface) → **Set LED at 3D cursor**. Not sure yet? Put it anywhere — moving it later takes seconds |

Press **Export to app**. It:

1. writes `assets/models/<slug>.glb` (modifiers applied, glTF Y-up),
2. creates or updates the model's entry in `tool/blender/models.json`,
3. starts the factory for that model in the background — the panel shows *Factory running…* and then
   *factory OK* (≈ 6–10 min) or *FAILED* with the reason.

Blender stays usable while it renders.

### Step 3 — check and commit

```bash
cd mobile/sempreiot_central_app
flutter test test/central/device_models_test.dart
```

Look at `assets/models/<slug>_atlas.png` and `_spin.png` and open Rede 3D, Dispositivos and the
Dispositivo screen of a unit of that product. Commit together: the `.blend`, the `.glb`, the sprite
files, `models.json`, `device_models.g.dart`, `pubspec.yaml` and `docs/sempreiot-system-reference.md`.

### Without Blender's panel

Same result from the shell: copy the `.glb` to `assets/models/<slug>.glb`, add an entry to `models.json`
([reference](#modelsjson-reference)), then

```bash
tool/blender/factory.sh <slug>
```

---

## Moving the LED

The LED's place is one entry per model, `markers.led` in `models.json`. Moving it **does not re-render
anything and does not touch the `.glb`**: the factory only recomputes where that point falls in each of
the 240 frames (a few seconds).

**From Blender:** open the model's `.blend`, pick its **Product** in the panel (its settings load), put the
3D cursor on the new spot → **Set LED at 3D cursor** → **Update LED only**.

**From the shell:** edit the point, then run the factory — it sees that only the LED changed:

```jsonc
"markers": {"led": {"point": [0, -0.034, 0.0125], "normal": [0, 0, 1]}}
//                            x right, y up, z toward the front — metres, glTF (the .glb's axes)
```

```bash
tool/blender/factory.sh siren            # only the LED changed → positions only
tool/blender/factory.sh siren --markers  # say so explicitly
```

Or point it at an object of the model (a modelled LED lens), and it follows that object:
`"led": {"object": "LED", "normal": [0, 0, 1]}`. `normal` is the direction the LED faces (front = `[0, 0, 1]`,
top = `[0, 1, 0]`); it decides when the dot is drawn slightly dimmed because the LED is on the far side.
A model without `led` gets the dot at the top centre.

---

## Alarm lights and sound

When the unit is in **ALARME** (`alarmLatched` — the same state as the ALARME badge), a model with:

- **`alarm.lights`** lights those parts up red — steadily on, with a double strobe flash every second and
  a red bloom around them (the siren: its whole lens);
- **`alarm.sound: true`** sends red sound waves out of both sides, one every 0.4 s.

It runs on Rede 3D, Dispositivos and Dispositivo. It is the unit's sounder and strobe, **not its status
LED**: the LED dot stays on top, in the LED language, unchanged. With *reduce motion* on, the lights are
shown lit and still, and the cards do not spin.

---

## Sizing: equal visual weight

Products differ in size and shape — a tall siren, a round detector, a square push button. The app does not
draw them at real size, nor by their largest side (that made the square push button look ~30 % heavier):
**every model gets the same visual weight**. The square root of the area its outline covers on screen is
`deviceModelVisualWeight` (0.79) × the layout size it is given — the circle's diameter: 46 px on Rede,
52 px on Rede 3D, 64 px on the Dispositivos cards, 72 px on Dispositivo. The factory measures each model's
`coverage`; the app computes the frame size from it (`deviceModelBox`). Nothing to set for a new product;
`scale` in `models.json` (panel: **Size adjust**) nudges one that still looks off.

---

## Updating an existing model

Change the `.blend`, select the product in the panel (its settings load), press **Export to app**.

From the shell:

```bash
tool/blender/factory.sh              # every model: re-render what changed, recompute moved LEDs, regenerate code
tool/blender/factory.sh siren        # just that model (re-rendered only if needed)
tool/blender/factory.sh --force      # re-render every model
tool/blender/factory.sh --markers    # only marker positions, never a render
tool/blender/factory.sh --codegen    # no Blender work: only device_models.g.dart, pubspec.yaml, §2.1.1
```

`--codegen` is what to run after editing only the product mapping (e.g. adding a second product to an
existing model) or after the §2.1 table changed. `BLENDER=/path/to/Blender` overrides the default
`/Applications/Blender.app/Contents/MacOS/Blender`.

---

## The model contract (what the `.glb` must look like)

| Rule | Why |
|---|---|
| Real size, **metres** | the camera frame and the light rig scale from the model's size |
| Front faces **−Y** in Blender (= **+Z** in the `.glb`) | yaw 0 / pitch 0 shows the front |
| One collection = one unit | the panel exports the visible objects of the active collection |
| Up is **+Z** in Blender | pitch > 0 = looking down from above |
| Real materials (Principled BSDF) | the images come straight from them, as rendered |
| Parts that light up in alarm are separate objects | `alarm.lights` selects them by name |
| Optional: an object for the LED (e.g. `LED`) | otherwise a point |

Where the model sits does not matter: the factory frames the bounding box of the visible objects.

---

## `models.json` reference

```jsonc
{
  "defaults": {                      // apply to every model unless it overrides them
    "size": 160,                     // frame side, px
    "yaws": [0, 15, …, 345],         // Rede 3D camera turns, degrees (24)
    "pitches": [-15, 0, …, 75],      // Rede 3D camera tilts, degrees (7) — the app's range is about −14°..69°
    "bodyFraction": 0.79,            // share of the frame the model's largest side fills (less for a boxy model: the frame also fits its diagonal)
    "scale": 1.0,                    // size nudge on top of the equal visual weight (see Sizing)
    "spin": {"pitch": 15, "step": 5, "cols": 12}   // the Dispositivos turn: tilt, step in degrees, sheet columns
  },
  "models": [
    {
      "slug": "siren",                       // required — assets/models/siren.glb, lower_snake_case
      "glb": "assets/models/siren.glb",      // required
      "products": ["SIOT-SIREN-01"],         // model strings from §2.1 (one or more)
      "familyFallback": "leaf",              // optional: "leaf" | "node" | "board"
      "scale": 1.0,                          // optional, default 1.0 — only to nudge a model that still looks off
      "orthoScale": 0.125,                   // optional: fixed frame size in metres instead of largest side / bodyFraction
      "hide": ["SIREN_Wire_*"],              // optional: object name patterns (fnmatch) left out of the renders
      "markers": {
        "led": {"point": [0, -0.034, 0.0125], "normal": [0, 0, 1]}   // glTF coords, metres
     // "led": {"object": "LED", "normal": [0, 0, 1]}                 // centre of an object
      },
      "alarm": {
        "lights": ["SIREN_Lens", "SIREN_Lens_Boss"],   // optional: object name patterns that light up red
        "sound": true                                  // optional: sound waves
      }
    }
  ]
}
```

A model needs `products`, `familyFallback`, or both. Marker and normal coordinates are **glTF**: x right,
y up, z toward the viewer (Blender `(x, y, z)` = glTF `(x, z, −y)`; the panel converts for you). Only the
`led` marker is used by the app today; other names are computed into `_frames.json` for later use.

---

## What the factory checks (and the errors it gives)

The factory stops with `[factory] ERROR: …` before rendering anything when:

| Error | Fix |
|---|---|
| `product 'X' is not in §2.1. Known: …` | typo, or the product is new → [step 0](#step-0--is-the-product-in-the-catalogue) |
| `X (0x…) is in §2.1 but not in SafrProduct.catalogue — add it there first` | add it to `safr_product.dart` with the same code |
| `X is mapped to both 'a' and 'b'` | a product has one model; remove it from one entry |
| `familyFallback 'leaf' on both 'a' and 'b'` | one stand-in per family |
| `slug 'X': lower_snake_case only` / `slug 'X' twice` | rename |
| `<slug>: assets/models/<slug>.glb not found` | export first, or fix `glb` |
| `marker 'led' object 'LED' not in the glb` | object names in the `.glb` are the Blender object names |
| `alarm lights [...] match no visible object in the glb` | fix the names / patterns, or check `hide` |
| `every mesh is hidden` | the `hide` patterns match everything |
| `the images are out of date too … run without --markers` | the `.glb` or the framing changed: a full run is needed |
| `markers '# >>> device-models' … not found` | the generated blocks in `pubspec.yaml` / the system reference were removed — put the two marker lines back |

`test/central/device_models_test.dart` then checks the result from the app's side: every model's codes
are in `SafrProduct.catalogue` and belong to its fallback family, no product or fallback is claimed twice,
every sprite file exists and is listed in `pubspec.yaml`, every model has an LED with one position per
frame, the lookup order below, and the widgets (spin, still Dispositivo, drag, alarm, LED always there).

---

## Inside the factory

`model_factory.py`, run by Blender in the background (`factory.sh` = `blender -b --factory-startup
--python model_factory.py -- …`). Your open Blender session is never touched.

1. **Read the catalogue** — the §2.1 table (`| \`0x0201\` | \`SIOT-SIREN-01\` | Siren … | node |`) and
   the codes in `safr_product.dart`; validate `models.json` against both.
2. **Decide the work per model**, from two fingerprints stored in its `_frames.json`:
   - *images* = the `.glb` bytes + what changes the pictures (framing, hidden objects, angles, alarm
     lights) + the factory version → changed: **render everything**;
   - *markers* = the `.glb` bytes + framing + `markers` → only this changed: **positions only**, no render.
   `--force` renders anyway, `--markers` never renders.
3. **Render** (images):
   - import the `.glb`, hide the `hide` objects, measure the bounding box of the rest;
   - orthographic camera tracking the box centre, frame = largest side ÷ `bodyFraction`, never less than
     the box's diagonal (so a boxy unit seen corner-on is not clipped), or `orthoScale` when set;
   - the same studio light as the original detector sprites (key top-left-front, fill right, rim behind),
     scaled to the model's size; EEVEE, AgX, transparent background;
   - the atlas angles, then the spin angles; then, for alarm lights, the same angles with those objects in
     white and everything else held out (so a light behind the cover stays hidden).
4. **Pack** each set into one sheet → `<slug>_atlas.png` (one row per tilt), `<slug>_spin.png`
   (12 per row), `<slug>_glow.png`, `<slug>_spin_glow.png`.
5. **Markers**: for every atlas and spin frame, where each marker falls (0..1 in the frame) and whether
   its normal faces the camera, and the model's **coverage** (mean share of the frame its outline covers
   over the spin turn) → `<slug>_frames.json` with sizes, angles, `bodyFraction`, coverage, alarm flags and
   both fingerprints.
6. **Generate**, for all models, only writing files that changed: `device_models.g.dart`, the
   `pubspec.yaml` block between `# >>> device-models` / `# <<< device-models`, the system reference §2.1.1
   table between `<!-- device-models:begin` / `<!-- device-models:end`.

A full render is ≈ 4 min for a model without alarm lights and ≈ 8 min with them on the dev Mac; an LED
move is a few seconds. Images are ~5 MB per model in the app.

---

## How the app uses it

`deviceModelFor(productCode, isLeaf:)` (`widgets/network_3d/device_model_sprites.dart`) chooses, in order:

1. the model whose `products` contain the unit's PRODUCT code;
2. else the model that is the `familyFallback` of the unit's family (from the code's high byte, or from
   `isLeaf` when the unit did not report a product);
3. else none → the unit stays a sphere / circle.

| Unit | Today |
|---|---|
| siren `0x0201` | siren model (red lights + sound waves in ALARME) |
| push-button station (manual call point) `0x0202` | push button model (LED on its green LED) |
| battery smoke detector `0x0301` | smoke detector model |
| battery heat detector `0x0302`, a leaf with no product reported | smoke detector (leaf fallback) |
| I/O module, repeater, AC smoke, bench units, board | sphere / circle |

Where the model is drawn:

| Screen | Widget | View |
|---|---|---|
| **Rede 3D** | `Model3dChip` (`network_3d/device_3d_chip.dart`) | the atlas frame for the map camera's turn and tilt |
| **Dispositivos** (the cards) | `DeviceModelAvatar` (`widgets/device_avatar.dart`), 64 px, `spin` | turning on itself, one turn every 7 s, at 15° above |
| **Dispositivo** (the header) | `DeviceModelAvatar`, 72 px, `interactive` | still, three-quarter from the front (turned 30°) — tapping a card opens it like this; a horizontal drag turns it, a double tap puts it back |
| Rede (2D map), device menu | `DeviceAvatar` — the circle | unchanged |

Everywhere the model is drawn as rendered (no outline) by the same `DeviceModelPainter`, with the LED dot
on the model's LED (always shown), the status dot, the sleeping moon and the ALARME / ROOT / CANDIDATO
badges; an offline unit is slightly faded. `DeviceModelAvatar` keeps the circle's footprint and is the
circle itself for a unit without a model or while the model loads, so a list never jumps.

---

## Files

| File | Edited by |
|---|---|
| `tool/blender/README.md` | you — this page |
| `tool/blender/models.json` | the panel or you — which `.glb` draws which product, its LED, its alarm lights |
| `tool/blender/model_factory.py` | the factory itself |
| `tool/blender/factory.sh` | the shell entry point |
| `tool/blender/sempreiot_model_export.py` | the Blender add-on (SempreIoT panel) |
| `assets/models/<slug>.blend` | you — the model's source |
| `assets/models/<slug>.glb` | the panel (export) |
| `assets/models/<slug>_atlas.png`, `_spin.png`, `_glow.png`, `_spin_glow.png`, `_frames.json` | **generated** |
| `lib/features/central/presentation/widgets/network_3d/device_models.g.dart` | **generated** |
| `pubspec.yaml` (between the `device-models` markers) | **generated** |
| `docs/sempreiot-system-reference.md` §2.1.1 (between the markers) | **generated** |
| `lib/features/central/presentation/widgets/network_3d/device_model_sprites.dart` | app code: `DeviceModelSpec`, `deviceModelFor`, `DeviceModelFrames`, `ModelPose`, `DeviceModelSprites` |
| `lib/features/central/presentation/widgets/network_3d/device_model_painter.dart` | app code: `DeviceModelPainter` (the model, the alarm lights and waves) |
| `lib/features/central/presentation/widgets/network_3d/device_3d_chip.dart` | app code: `Model3dChip` (Rede 3D) |
| `lib/features/central/presentation/widgets/device_avatar.dart` | app code: `DeviceModelAvatar` (Dispositivos, Dispositivo) |
| `test/central/device_models_test.dart` | the registry, assets, lookup and widget tests |
