"""Packs PNG frames into one image with numpy (Blender's Python).
  blender -b --python sheet.py -- <out.png> <cols> <bg r,g,b,a> <frame paths...>"""
import bpy, sys, numpy as np
args = sys.argv[sys.argv.index("--") + 1:]
out, cols, bg, paths = args[0], int(args[1]), [float(x) for x in args[2].split(",")], args[3:]
imgs = [bpy.data.images.load(p) for p in paths]
w, h = imgs[0].size
rows = (len(imgs) + cols - 1) // cols
sheet = np.zeros((rows * h, cols * w, 4), dtype=np.float32); sheet[:] = bg
for i, im in enumerate(imgs):
    px = np.array(im.pixels[:], dtype=np.float32).reshape(h, w, 4)  # bottom-up rows
    r, c = i // cols, i % cols
    y0 = (rows - 1 - r) * h  # Blender images are bottom-up
    dst = sheet[y0:y0 + h, c * w:(c + 1) * w]
    if bg[3] > 0:  # composite over the background
        a = px[..., 3:4]
        dst[..., :3] = px[..., :3] * a + dst[..., :3] * (1 - a); dst[..., 3] = 1
    else:
        dst[:] = px
res = bpy.data.images.new("sheet", cols * w, rows * h, alpha=True)
res.pixels[:] = sheet.ravel()
res.filepath_raw = out; res.file_format = "PNG"; res.save()
print("SHEET", out, cols * w, rows * h)
