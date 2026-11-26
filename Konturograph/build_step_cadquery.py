import cadquery as cq, math, sys
OUT = sys.argv[1]
# ---------- Hauptblock ----------
L, B, H = 310.0, 310.0, 100.0
D, T = 20.0, 50.0                  # hole dia / blind depth (solid underneath)
NX, NY, M = 7, 4, 17.5             # 7 per row, 4 rows, edge wall 17.5 (15<x<20)
px = (L - 2*M - D)/(NX-1); py = (B - 2*M - D)/(NY-1)
pts = [(M+D/2+i*px, M+D/2+j*py) for j in range(NY) for i in range(NX)]
blk = cq.Workplane("XY").box(L, B, H, centered=False)
blk = blk.faces(">Z").workplane(origin=(0,0,H)).pushPoints(pts).hole(D, T)
# dovetail groove on right face (x=L), along Y, centred z=75
gw, gd, ang = 16.0, 6.0, math.radians(30); zc = 75.0
w2 = gw/2 + gd*math.tan(ang)
gp = [(L, zc-gw/2), (L-gd, zc-w2), (L-gd, zc+w2), (L, zc+gw/2)]
groove = cq.Workplane("XZ").polyline([(x, z) for x, z in gp]).close().extrude(-B)
blk = blk.cut(groove)
# ---------- Seitenschale ----------
TL, TW, TH, wall, cl = 150.0, 120.0, 50.0, 4.0, 0.2
tray = cq.Workplane("XY").box(TW, TL, TH, centered=False)
tray = tray.cut(cq.Workplane("XY").box(TW-2*wall, 82, 35, centered=False).translate((wall, 64, TH-35)))
rows = {43.0: [1.5, 1.0, 2.5], 17.0: [3.0, 2.5, 1.5]}
for y, ds in rows.items():
    for x, d in zip([25.0, 60.0, 95.0], ds):
        tray = tray.cut(cq.Workplane("XY").circle(d/2).extrude(12).translate((x, y, TH-12)))
tz = zc - (H - TH)   # tongue centre in tray coords = 25
td = gd - cl; tw0 = gw - 2*cl; tw1 = tw0/2 + td*math.tan(ang)
tp = [(0, tz-tw0/2), (-td, tz-tw1), (-td, tz+tw1), (0, tz+tw0/2)]
tongue = cq.Workplane("XZ").polyline(tp).close().extrude(-TL)
tray = tray.union(tongue)
cq.exporters.export(blk, f"{OUT}/Bolzenhalter_Flach_28Loch_v7.step")
cq.exporters.export(tray, f"{OUT}/Bolzen_Seitenschale_v1.step")
asm = cq.Assembly().add(blk, name="Block", color=cq.Color(0.25,0.27,0.3)).add(
    tray, name="Schale", loc=cq.Location((L+0.0, 0, H-TH)), color=cq.Color(0.2,0.45,0.75))
asm.save(f"{OUT}/Konturograph_Baugruppe.step")
for n, s in [("block", blk), ("tray", tray)]:
    sol = s.val(); bb = sol.BoundingBox()
    print(n, "valid", sol.isValid(), "vol cm3 %.0f" % (sol.Volume()/1000), "bb", [round(v,2) for v in (bb.xmin,bb.ymin,bb.zmin,bb.xmax,bb.ymax,bb.zmax)])
# interference check
inter = blk.val().intersect(tray.val().translate(cq.Vector(L, 0, H-TH)))
print("interference vol", round(inter.Volume(), 4), "pitch", px, py)
