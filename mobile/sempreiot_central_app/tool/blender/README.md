# Detector sprites for Rede 3D (prototype)

`assets/models/smoke_detector.glb` is pre-rendered into sprites the app draws
(no 3D engine at runtime): 24 turns × 7 tilts, a rim mask tinted with the
status colour, and the LED lens position per frame.

Regenerate after changing the model (Blender 5.x, ~4 min):

```bash
B=/Applications/Blender.app/Contents/MacOS/Blender
OUT=/tmp/detector_sprites; M=assets/models
mkdir -p $OUT/c $OUT/r
$B -b --python tool/blender/render_detector_sprites.py -- $OUT atlas
$B -b --python tool/blender/pack_sheet.py -- $M/smoke_detector_atlas.png 24 "0,0,0,0" $(ls $OUT/c/*.png)
$B -b --python tool/blender/pack_sheet.py -- $M/smoke_detector_rim.png 24 "0,0,0,0" $(ls $OUT/r/*.png)
cp $OUT/frames.json $M/smoke_detector_frames.json
```

`render_detector_sprites.py -- <out> preview` renders 8 angles to eyeball the look.
Model contract: Y up, face (+LED) toward +Z, objects `Body`, `LED`, `Rim`.
