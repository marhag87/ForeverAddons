# Regenerates Nodes.lua, copies node artwork, and libs (node IDs are taken from the Forever data) from GatherMate2 + the data repo.
import re, os, shutil, glob
GM = r"D:/Games/World of Warcraft/_classic_beta_/Interface/AddOns/GatherMate2"
OUT = r"D:/Games/World of Warcraft/_classic_beta_/Interface/AddOns/GatherReference"
DATA = r"D:/Games/World of Warcraft/_classic_beta_/Interface/AddOns/GatherMate2_Data/Forever"
src = open(os.path.join(GM, "Constants.lua"), encoding="utf-8").read().splitlines()
cats = {"Fishing":"Fish","Mining":"Mine","Herb Gathering":"Herb","Treasure":"Treasure"}
names = {}; tex = {}
section = None; cat = None
for line in src:
    if line.startswith("local node_ids"): section = "ids"
    elif line.startswith("local node_textures"): section = "tex"
    elif line.startswith("}"): section = None if section else None
    m = re.match(r'^\t\["([^"]+)"\] = \{', line)
    if m: cat = cats.get(m.group(1))
    if section == "ids" and cat:
        m = re.search(r'^\s*(?:--)?\s*\[NL\["(.+?)"\]\]\s*=\s*(\d+)', line)
        if m: names.setdefault((cat, int(m.group(2))), m.group(1))
    if section == "tex" and cat:
        m = re.search(r'^\s*(?:--)?\s*\[(\d+)\]\s*=\s*icon_path\.\."(.+?)"', line)
        if m: tex[(cat, int(m.group(1)))] = m.group(2)
used = {}
for f, cat in [("HerbalismData","Herb"),("MiningData","Mine"),("TreasureData","Treasure"),("FishData","Fish")]:
    ids = sorted({int(x) for x in re.findall(r'= (\d+),', open(os.path.join(DATA, f+".lua")).read())})
    used[cat] = ids
lines = ["-- Generated from GatherMate2's Constants.lua (enUS names). nodeID = { name, texture }", "local _, ns = ...", "ns.nodes = {"]
for cat in ["Herb","Mine","Fish","Treasure"]:
    lines.append(f'\t{cat} = {{')
    for i in used[cat]:
        n = names.get((cat,i), f"Unknown {i}"); t = tex.get((cat,i))
        if not t: print("missing tex", cat, i)
        rel = t.replace("\\\\", "/")
        os.makedirs(os.path.join(OUT, "Artwork", os.path.dirname(rel)), exist_ok=True)
        shutil.copy(os.path.join(GM, "Artwork", rel), os.path.join(OUT, "Artwork", rel))
        lines.append(f'\t\t[{i}] = {{ "{n}", [[Interface\AddOns\GatherReference\Artwork\{t.replace(chr(92)*2, chr(92))}]] }},')
    lines.append("\t},")
lines.append("}")
open(os.path.join(OUT, "Nodes.lua"), "w", encoding="utf-8", newline="\n").write("\n".join(lines)+"\n")
for d in ["LibStub","CallbackHandler-1.0"]:
    shutil.copytree(os.path.join(GM,"Libs",d), os.path.join(OUT,"Libs",d), dirs_exist_ok=True)
os.makedirs(os.path.join(OUT,"Libs","HereBeDragons"), exist_ok=True)
shutil.copy(os.path.join(GM,"Libs","HereBeDragons","HereBeDragons-2.0.lua"), os.path.join(OUT,"Libs","HereBeDragons"))
shutil.copy(os.path.join(GM,"Artwork","track_circle.tga"), os.path.join(OUT,"Artwork"))
