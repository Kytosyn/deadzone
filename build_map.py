#!/usr/bin/env python3
"""build_map.py - generate the DEAD ZONE greybox map as Rojo source.

Why a script: the map is ~150 parts with heavy repetition (4 zones x spawn
pads, gates, walls, loot). Regenerating it keeps the layout tweakable in one
place, and the output is plain JSON that Rojo compiles into the .rbxl.

Output layout (mirrors what the server code looks up):

    Workspace.DeadZone.Zones/<zoneId>/**   Attribute Role = "SpawnPoint" | "Extraction"
    Workspace.DeadZone.Gates/<zoneId>/**   any BasePart
    Workspace.DeadZone.Loot/**             Attribute Role = "Pickup", Kind = <pickup>

Usage:
    python3 build_map.py          # writes map/ next to this script
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "map")

ZONE_SPACING = 160
ZONE_SIZE = 120
WALL_HEIGHT = 14
WALL_THICKNESS = 4
SPAWN_COUNT = 4

ZONES = [
    {"id": "suburbs", "danger": 1, "special": "Hunter"},
    {"id": "hospital", "danger": 2, "special": "Boomer"},
    {"id": "mall", "danger": 3, "special": "Charger"},
    {"id": "base", "danger": 4, "special": "Tank"},
]

LOOT_KINDS = ["Medkit", "Pills", "Adrenaline", "AmmoPile", "Bandage"]

ZONE_LOOT = {
    "suburbs": [1, 1, 0, 1, 0],
    "hospital": [1, 0, 1, 1, 1],
    "mall": [1, 1, 1, 1, 1],
    "base": [1, 1, 1, 2, 1],
}

COLORS = {
    "ground": (70, 70, 74),
    "wall": (45, 45, 50),
    "cover": (60, 55, 48),
    "cover2": (55, 60, 58),
    "spawn": (60, 140, 70),
    "gate": (150, 120, 40),
    "gatepost": (110, 90, 35),
    "extract": (70, 110, 190),
    "loot": (190, 170, 60),
}


class Part:
    def __init__(self, name, pos, size, color, role=None, kind=None, anchored=True):
        self.name = name
        self.pos = pos
        self.size = size
        self.color = color
        self.role = role
        self.kind = kind
        self.anchored = anchored

    def as_dict(self):
        x, y, z = self.pos
        sx, sy, sz = self.size
        d = {
            "ClassName": "Part",
            "Name": self.name,
            "Anchored": self.anchored,
            "Position": [x, y, z],
            "Size": [sx, sy, sz],
            "Color": list(COLORS[self.color]),
        }
        props = {}
        if self.role:
            props["Role"] = self.role
        if self.kind:
            props["Kind"] = self.kind
        if props:
            # Rojo: custom tags are Attributes, not Properties - Properties only
            # accepts real engine properties, and the server reads these back
            # with GetAttribute("Role") / GetAttribute("Kind").
            d["Attributes"] = props
        return d


def zone_parts(zone, zi):
    zid = zone["id"]
    origin_z = zi * ZONE_SPACING
    half = ZONE_SIZE / 2
    parts = []

    # Ground slab.
    parts.append(Part(f"{zid}_ground", (0, -1, origin_z), (ZONE_SIZE, 2, ZONE_SIZE), "ground"))

    # Perimeter walls - keeps the squad inside the zone.
    walls = [
        (0, origin_z - half, ZONE_SIZE + WALL_THICKNESS, WALL_THICKNESS),
        (0, origin_z + half, ZONE_SIZE + WALL_THICKNESS, WALL_THICKNESS),
        (-half, origin_z, WALL_THICKNESS, ZONE_SIZE + WALL_THICKNESS),
        (half, origin_z, WALL_THICKNESS, ZONE_SIZE + WALL_THICKNESS),
    ]
    for i, (wx, wz, sx, sz) in enumerate(walls):
        parts.append(Part(f"{zid}_wall_{i + 1}", (wx, WALL_HEIGHT / 2, wz), (sx, WALL_HEIGHT, sz), "wall"))

    # Cover geometry so pathing and the melee shove have obstacles.
    parts.append(Part(f"{zid}_cover_a", (-25, 3, origin_z - 20), (16, 6, 4), "cover"))
    parts.append(Part(f"{zid}_cover_b", (28, 4, origin_z + 25), (4, 8, 18), "cover"))
    parts.append(Part(f"{zid}_cover_c", (5, 2, origin_z + 5), (10, 4, 10), "cover2"))

    # Spawn pads: one per squad member, near the zone's entry edge.
    for si in range(SPAWN_COUNT):
        px = (si - (SPAWN_COUNT - 1) / 2.0) * 6
        parts.append(
            Part(
                f"{zid}_spawn_{si + 1}",
                (px, 0.5, origin_z - half + 10),
                (4, 1, 4),
                "spawn",
                role="SpawnPoint",
            )
        )

    # Loot spread along the zone's central axis.
    wanted = ZONE_LOOT.get(zid, [])
    for li, kind in enumerate(LOOT_KINDS):
        count = wanted[li] if li < len(wanted) else 0
        for ci in range(count):
            lx = -40 + li * 16 + ci * 7
            lz = origin_z - 30 + li * 12 + ci * 5
            parts.append(
                Part(
                    f"loot_{kind}_{ci + 1}",
                    (lx, 1.5, lz),
                    (2, 3, 2),
                    "loot",
                    role="Pickup",
                    kind=kind,
                )
            )

    return parts, origin_z, half


def gate_parts(zone, zi):
    zid = zone["id"]
    origin_z = zi * ZONE_SPACING
    half = ZONE_SIZE / 2
    gz = origin_z + half - 6
    return [
        Part(f"{zid}_gate", (0, 7, gz), (20, 14, 4), "gate"),
        Part(f"{zid}_gatepost_l", (-12, 7, gz), (3, 14, 5), "gatepost"),
        Part(f"{zid}_gatepost_r", (12, 7, gz), (3, 14, 5), "gatepost"),
    ]


def write_model(path, parts, folder_class="Folder"):
    """Write a Rojo .model.json: {className, children:[...]}"""
    doc = {
        "className": folder_class,
        "children": [p.as_dict() for p in parts],
    }
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(doc, fh, indent=2)
    return len(parts)


def main():
    if os.path.isdir(OUT_DIR):
        for root, dirs, files in os.walk(OUT_DIR, topdown=False):
            for f in files:
                os.remove(os.path.join(root, f))
            for d in dirs:
                os.rmdir(os.path.join(root, d))

    total = 0
    summary = {}

    for zi, zone in enumerate(ZONES):
        zid = zone["id"]
        parts, origin_z, half = zone_parts(zone, zi)

        # Extraction pad only exists on the final zone.
        if zone is ZONES[-1]:
            parts.append(
                Part(
                    f"{zid}_extract",
                    (0, 0.5, origin_z + half - 22),
                    (12, 1, 12),
                    "extract",
                    role="Extraction",
                )
            )

        n = write_model(os.path.join(OUT_DIR, "Zones", zid, "init.model.json"), parts)
        summary[f"Zones/{zid}"] = n
        total += n

        g = gate_parts(zone, zi)
        n = write_model(os.path.join(OUT_DIR, "Gates", zid, "init.model.json"), g)
        summary[f"Gates/{zid}"] = n
        total += n

    # Loot lives at DeadZone.Loot, not per-zone.
    loot_parts = []
    for zi, zone in enumerate(ZONES):
        zid = zone["id"]
        for p in zone_parts(zone, zi)[0]:
            if p.name.startswith("loot_"):
                p.name = f"{zid}_{p.name}"
                loot_parts.append(p)

    n = write_model(os.path.join(OUT_DIR, "Loot", "init.model.json"), loot_parts)
    summary["Loot"] = n
    total += n

    with open(os.path.join(OUT_DIR, "meta.json"), "w") as fh:
        json.dump({"folders": summary, "total_parts": total}, fh, indent=2)

    print(f"wrote {total} parts across {len(summary)} folders -> {OUT_DIR}")


if __name__ == "__main__":
    main()
