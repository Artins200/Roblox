"""
volcano_map.py -- procedural geometry for the "Лавовый каньон" arena.

Everything is built from primitive Roblox parts (no external assets), so the
place opens and looks complete without an internet connection.  The art
direction follows the reference slide: black basalt islands floating over a
glowing lava sea, cracked lava crust, lavafalls, chains, wooden warning signs,
torches and a volcanic castle on the horizon.
"""

import math
import random

from rbxlx import (
    CF, Content, Inst, NumRange, NumSeq, ColSeq, UDim2, Vec2, Vec3,
    ball, cf, cf_angles, cylinder, particles, part, point_light,
    rgb, surface_sign, wedge, ENUMS,
)

# --------------------------------------------------------------------------- #
# palette
# --------------------------------------------------------------------------- #
ROCK_DEEP = rgb(24, 21, 23)
ROCK_DARK = rgb(38, 33, 35)
ROCK_MID = rgb(56, 48, 48)
ROCK_LIGHT = rgb(86, 74, 68)
ROCK_WARM = rgb(74, 44, 36)
ROCK_ASH = rgb(96, 88, 84)
LAVA_CORE = rgb(255, 108, 16)
LAVA_HOT = rgb(255, 172, 52)
LAVA_DEEP = rgb(206, 48, 0)
METAL_DARK = rgb(40, 38, 42)
METAL_LIGHT = rgb(104, 100, 106)
WOOD = rgb(64, 42, 28)
CYAN = rgb(70, 220, 255)

ROCK_MATS = ["Slate", "Basalt", "Rock", "Slate", "Basalt", "Concrete"]
ROCK_COLORS = (ROCK_DARK, ROCK_MID, ROCK_LIGHT, ROCK_WARM, ROCK_DEEP)


# --------------------------------------------------------------------------- #
# primitives
# --------------------------------------------------------------------------- #
def disc(name, height, diameter, pos, color=ROCK_DARK, material="Slate",
         transparency=0.0, cancollide=True, castshadow=True, yaw=0.0):
    """A vertical cylinder, i.e. a round slab."""
    return cylinder(name, (height, diameter, diameter), pos, (0.0, yaw, 90.0),
                    color=color, material=material, transparency=transparency,
                    cancollide=cancollide, castshadow=castshadow, canquery=cancollide)


def lava_slab(name, size, pos, rot=None, color=LAVA_CORE, transparency=0.02):
    return part(name, size, pos, rot, color=color, material="Neon",
                transparency=transparency, cancollide=False, anchored=True,
                castshadow=False, canquery=False)


def glow_light(name, brightness=3.0, rng=60.0, color=(255, 130, 40), shadows=False):
    return point_light(None, color=color, brightness=brightness, rng=rng,
                       shadows=shadows, name=name)


def ember_emitter(name="Embers", rate=14.0, lifetime=(3.0, 6.0), speed=(6.0, 22.0),
                  size=(0.35, 1.5), accel=(0, 14, 0), color_a=(255, 180, 90),
                  color_b=(120, 26, 0)):
    return particles(
        name, rate=rate, lifetime=lifetime, speed=speed,
        size=[(0.0, size[0]), (0.45, size[1]), (1.0, 0.0)],
        color_keys=[(0.0, rgb(*color_a)), (0.55, rgb(255, 120, 40)), (1.0, rgb(*color_b))],
        transparency_keys=[(0.0, 0.15), (0.7, 0.55), (1.0, 1.0)],
        accel=accel, drag=1.2, spread=(180, 180), light_emission=0.9, brightness=1.6,
        emission_direction="Top",
    )


def smoke_emitter(name="Smoke", rate=6.0, lifetime=(9.0, 16.0), speed=(3.0, 9.0),
                  size=(14.0, 40.0)):
    return particles(
        name, rate=rate, lifetime=lifetime, speed=speed,
        size=[(0.0, size[0]), (0.5, size[1]), (1.0, size[1] * 1.5)],
        color_keys=[(0.0, rgb(54, 38, 32)), (1.0, rgb(18, 14, 14))],
        transparency_keys=[(0.0, 0.55), (1.0, 1.0)],
        accel=(2.5, 6, 0), drag=0.4, spread=(120, 120), light_emission=0.0,
        brightness=0.2, emission_direction="Top",
    )


def torch(parent, pos, height=7.0, light_range=48.0, scale=1.0):
    """Wooden torch: post + glowing flame + light + fire particles."""
    x, y, z = pos
    post = part("TorchPost", (0.7 * scale, height * scale, 0.7 * scale),
                (x, y + height * scale / 2, z), color=WOOD, material="Wood",
                cancollide=False)
    cup = part("TorchCup", (1.5 * scale, 1.1 * scale, 1.5 * scale),
               (x, y + height * scale, z), color=METAL_DARK, material="Metal",
               cancollide=False)
    flame = part("TorchFlame", (1.9 * scale, 2.6 * scale, 1.9 * scale),
                 (x, y + height * scale + 1.4 * scale, z), color=rgb(255, 160, 40),
                 material="Neon", transparency=0.12, cancollide=False,
                 castshadow=False, canquery=False, shape="Ball")
    flame.add(ember_emitter("Flame", rate=40, lifetime=(0.45, 0.9), speed=(5, 12),
                            size=(0.9, 2.4), accel=(0, 26, 0)))
    flame.add(glow_light("TorchLight", brightness=3.4, rng=light_range))
    parent.add(post, cup, flame)
    return flame


def chain(parent, a, b, links=None, sag=0.22, thickness=0.55, color=ROCK_DEEP):
    """A catenary chain made of alternating little links."""
    a = a if isinstance(a, Vec3) else Vec3(*a)
    b = b if isinstance(b, Vec3) else Vec3(*b)
    dist = (b - a).length()
    if links is None:
        links = max(6, int(dist / 3.2))
    mid = Vec3((a.x + b.x) / 2, (a.y + b.y) / 2 - dist * sag, (a.z + b.z) / 2)
    pts = []
    for i in range(links + 1):
        t = i / links
        pts.append(a * ((1 - t) ** 2) + mid * (2 * (1 - t) * t) + b * (t * t))
    for i in range(links):
        p0, p1 = pts[i], pts[i + 1]
        d = p1 - p0
        ln = max(d.length(), 0.01)
        yaw = math.degrees(math.atan2(-d.x, -d.z))
        pitch = math.degrees(math.asin(max(-1.0, min(1.0, d.y / ln))))
        roll = 90.0 if i % 2 == 0 else 0.0
        parent.add(part("ChainLink", (thickness, thickness, ln * 1.15),
                        ((p0.x + p1.x) / 2, (p0.y + p1.y) / 2, (p0.z + p1.z) / 2),
                        rot=(pitch, yaw, roll), color=color, material="Metal",
                        cancollide=False, castshadow=False, canquery=False))
    return pts


def lava_fall(parent, top, width=9.0, drop=44.0, face_yaw=0.0, with_light=True):
    """A glowing sheet of lava pouring off an edge."""
    x, y, z = top
    sheet = lava_slab("LavaFall", (width, drop, 1.6), (x, y - drop / 2, z),
                      rot=(0, face_yaw, 0), color=LAVA_CORE, transparency=0.06)
    sheet.add(ember_emitter("FallSpray", rate=26, lifetime=(1.2, 2.6), speed=(4, 14),
                            size=(0.5, 1.6), accel=(0, -6, 0)))
    if with_light:
        sheet.add(glow_light("FallLight", brightness=3.0, rng=70))
    for i in range(3):
        yy = y - drop * (0.25 + i * 0.28)
        sheet.add(lava_slab("Ripple", (width * (1.0 + i * 0.12), 1.1, 2.4),
                            (x, yy, z), rot=(0, face_yaw, 0), color=LAVA_HOT,
                            transparency=0.25))
    parent.add(sheet)
    return sheet


def crack(parent, a, b, width=1.6, color=LAVA_HOT):
    """A glowing crack on a surface between two points."""
    dx, dy, dz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
    ln = math.sqrt(dx * dx + dy * dy + dz * dz)
    if ln < 0.05:
        return None
    yaw = math.degrees(math.atan2(-dx, -dz))
    pitch = -math.degrees(math.asin(max(-1.0, min(1.0, dy / ln))))
    inst = lava_slab("LavaCrack", (width, 0.45, ln),
                     ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2 + 0.3, (a[2] + b[2]) / 2),
                     rot=(pitch, yaw, 0), color=color, transparency=0.0)
    parent.add(inst)
    return inst


# --------------------------------------------------------------------------- #
# islands
# --------------------------------------------------------------------------- #
def rock_field(rng, parent, center, radius, count, base_y, hei=8.0, spread=1.0):
    cx, cy, cz = center
    for _ in range(count):
        ang = rng.uniform(0, math.tau)
        rad = radius * math.sqrt(rng.random()) * spread
        x = cx + math.cos(ang) * rad
        z = cz + math.sin(ang) * rad
        s = rng.uniform(0.55, 1.35)
        sy = rng.uniform(0.6, 2.2) * hei
        parent.add(part("Rock", (rng.uniform(4, 13) * s, sy, rng.uniform(4, 13) * s),
                        (x, base_y + rng.uniform(-1.4, 1.2) - sy * 0.15, z),
                        rot=(rng.uniform(-9, 9), rng.uniform(0, 360), rng.uniform(-9, 9)),
                        color=rng.choice(ROCK_COLORS), material=rng.choice(ROCK_MATS)))


def jagged_underside(rng, parent, center, top_y, radius, depth, tiers=4):
    cx, cy, cz = center
    for i in range(tiers):
        t = (i + 1) / tiers
        tier_r = radius * (1.0 - t * 0.72)
        h = depth / tiers * rng.uniform(1.0, 1.5)
        y = top_y - depth * t * 0.85
        parent.add(disc("UnderRock", h, tier_r * 2,
                        (cx + rng.uniform(-0.1, 0.1) * radius, y,
                         cz + rng.uniform(-0.1, 0.1) * radius),
                        color=rng.choice((ROCK_DEEP, ROCK_DARK, ROCK_MID)),
                        material=rng.choice(("Slate", "Basalt", "Rock")),
                        yaw=rng.uniform(0, 360)))
    for _ in range(10):
        ang = rng.uniform(0, math.tau)
        rad = radius * rng.uniform(0.15, 0.8)
        h = rng.uniform(depth * 0.5, depth * 1.15)
        w = rng.uniform(3, 9)
        parent.add(part("Spike", (w, h, w),
                        (cx + math.cos(ang) * rad, top_y - depth * 0.72 - h * 0.35,
                         cz + math.sin(ang) * rad),
                        rot=(rng.uniform(-6, 6), rng.uniform(0, 360), rng.uniform(-6, 6)),
                        color=rng.choice((ROCK_DEEP, ROCK_DARK)), material="Slate",
                        castshadow=False))


def island(rng, parent, center, radius, depth=70.0, rocks=28, edge_rocks=26,
           lava_rim=True, torches=2, name="Island", falls=2):
    folder = Inst("Folder", name)
    parent.add(folder)
    cx, cy, cz = center

    folder.add(disc("IslandTop", 5.0, radius * 2.0, (cx, cy - 2.5, cz),
                    color=ROCK_DARK, material="Slate", yaw=rng.uniform(0, 360)))
    folder.add(disc("IslandTop2", 7.0, radius * 1.78,
                    (cx + rng.uniform(-0.05, 0.05) * radius, cy - 7.0,
                     cz + rng.uniform(-0.05, 0.05) * radius),
                    color=ROCK_MID, material="Concrete", yaw=rng.uniform(0, 360)))
    folder.add(disc("IslandBelly", 9.0, radius * 1.5, (cx, cy - 13.0, cz),
                    color=ROCK_DARK, material="Basalt", yaw=rng.uniform(0, 360)))

    rock_field(rng, folder, (cx, cy + 0.3, cz), radius, rocks, cy, hei=6.5, spread=0.98)

    for i in range(edge_rocks):
        ang = (i / edge_rocks) * math.tau + rng.uniform(-0.05, 0.05)
        rad = radius * rng.uniform(0.86, 1.02)
        h = rng.uniform(4, 16)
        w = rng.uniform(6, 16)
        folder.add(part("RimRock", (w, h, w * rng.uniform(0.7, 1.3)),
                        (cx + math.cos(ang) * rad, cy + h * rng.uniform(0.1, 0.45) - h / 2,
                         cz + math.sin(ang) * rad),
                        rot=(rng.uniform(-14, 14), math.degrees(ang) + rng.uniform(-25, 25),
                             rng.uniform(-14, 14)),
                        color=rng.choice(ROCK_COLORS), material=rng.choice(ROCK_MATS)))

    jagged_underside(rng, folder, (cx, cy - 16.0, cz), cy - 16.0, radius * 0.78, depth)

    if lava_rim:
        for i in range(10):
            ang = (i / 10) * math.tau + rng.uniform(-0.15, 0.15)
            rad = radius * rng.uniform(0.62, 0.95)
            ln = rng.uniform(5, 16)
            x, z = cx + math.cos(ang) * rad, cz + math.sin(ang) * rad
            crack(folder,
                  (x - math.cos(ang) * ln / 2, cy + 0.1, z - math.sin(ang) * ln / 2),
                  (x + math.cos(ang) * ln / 2, cy + 0.1, z + math.sin(ang) * ln / 2),
                  width=rng.uniform(1.0, 2.6),
                  color=rng.choice((LAVA_HOT, LAVA_CORE)))

    for _ in range(falls):
        ang = rng.uniform(0, math.tau)
        rad = radius * 0.97
        lava_fall(folder, (cx + math.cos(ang) * rad, cy - 1.0, cz + math.sin(ang) * rad),
                  width=rng.uniform(6, 13), drop=rng.uniform(30, depth * 0.9),
                  face_yaw=-math.degrees(ang) + 90.0)

    for i in range(torches):
        ang = (i / max(1, torches)) * math.tau + 0.6
        rad = radius * 0.62
        torch(folder, (cx + math.cos(ang) * rad, cy, cz + math.sin(ang) * rad),
              height=rng.uniform(6, 8), scale=rng.uniform(0.9, 1.3))

    return folder


# --------------------------------------------------------------------------- #
# castle
# --------------------------------------------------------------------------- #
def crenellations(parent, cx, cy, cz, radius, count, block=(3.2, 3.4, 3.2)):
    for i in range(count):
        ang = (i / count) * math.tau
        parent.add(part("Crenel", block,
                        (cx + math.cos(ang) * radius, cy + block[1] / 2,
                         cz + math.sin(ang) * radius),
                        rot=(0, -math.degrees(ang), 0), color=ROCK_MID,
                        material="Concrete"))


def tower(rng, parent, cx, cz, base_y, height=90.0, radius=15.0, roof=True):
    folder = Inst("Folder", "Tower")
    parent.add(folder)
    folder.add(disc("TowerBody", height, radius * 2, (cx, base_y + height / 2, cz),
                    color=ROCK_MID, material="Concrete", yaw=rng.uniform(0, 90)))
    folder.add(disc("TowerBand", 4.0, radius * 2.16, (cx, base_y + height * 0.42, cz),
                    color=ROCK_DARK, material="Slate"))
    folder.add(disc("TowerTop", 4.0, radius * 2.3, (cx, base_y + height, cz),
                    color=ROCK_LIGHT, material="Concrete"))
    crenellations(folder, cx, base_y + height + 2.0, cz, radius * 1.05, 10)
    if roof:
        y = base_y + height + 5.0
        r = radius * 1.15
        for i in range(5):
            folder.add(disc("Roof", 5.0, r * 2, (cx, y, cz),
                            color=rng.choice((ROCK_DARK, ROCK_WARM, rgb(92, 40, 34))),
                            material="Slate", yaw=rng.uniform(0, 60)))
            y += 5.0
            r *= 0.68
        beacon = ball("Beacon", (6, 6, 6), (cx, y + 2.5, cz), color=LAVA_HOT,
                      material="Neon", cancollide=False, castshadow=False)
        beacon.add(glow_light("BeaconLight", brightness=4.0, rng=70))
        beacon.add(ember_emitter("BeaconEmbers", rate=12, lifetime=(2, 4), speed=(4, 10)))
        folder.add(beacon)
    for i in range(3):
        folder.add(part("Window", (2.0, 6.0, radius * 1.9),
                        (cx, base_y + height * (0.3 + i * 0.22), cz),
                        color=rgb(255, 150, 50), material="Neon", transparency=0.15,
                        cancollide=False, castshadow=False, canquery=False))
    return folder


def castle(rng, parent, center, top_y):
    folder = Inst("Folder", "VolcanoCastle")
    parent.add(folder)
    cx, cy, cz = center
    island(rng, folder, (cx, cy - 4, cz), 150.0, depth=120.0, rocks=30, edge_rocks=34,
           lava_rim=True, torches=4, name="CastlePlateau", falls=3)

    wall_h, half, base = 46.0, 62.0, cy
    length = half * 2
    for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        cxw, czw = cx + dx * half, cz + dz * half
        if dz == 1:
            seg = (length - 26.0) / 2
            for s in (-1, 1):
                folder.add(part("Wall", (seg, wall_h, 7.0),
                                (cxw + s * (seg / 2 + 13.0), base + wall_h / 2, czw),
                                color=ROCK_MID, material="Concrete"))
            folder.add(part("GateLintel", (26.0, wall_h - 26.0, 7.5),
                            (cxw, base + 26.0 + (wall_h - 26.0) / 2, czw),
                            color=ROCK_DARK, material="Slate"))
            for i in range(9):
                folder.add(part("Crenel", (5.0, 3.6, 5.0),
                                (cxw - length / 2 + 3 + i * (length - 6) / 8,
                                 base + wall_h + 1.8, czw),
                                color=ROCK_MID, material="Concrete"))
        else:
            folder.add(part("Wall", (7.0 if dx else length, wall_h, length if dx else 7.0),
                            (cxw, base + wall_h / 2, czw), color=ROCK_MID,
                            material="Concrete"))
            for i in range(9):
                off = -length / 2 + 3 + i * (length - 6) / 8
                folder.add(part("Crenel", (5.0, 3.6, 5.0),
                                (cxw + (0 if dx else off), base + wall_h + 1.8,
                                 czw + (0 if dz else off)),
                                color=ROCK_MID, material="Concrete"))

    for sx in (-1, 1):
        for sz in (-1, 1):
            tower(rng, folder, cx + sx * half, cz + sz * half, base, 78.0, 16.0)

    keep_h = 96.0
    folder.add(part("Keep", (62.0, keep_h, 62.0), (cx, base + keep_h / 2, cz),
                    color=ROCK_DARK, material="Slate"))
    folder.add(part("KeepTrim", (66.0, 5.0, 66.0), (cx, base + keep_h, cz),
                    color=ROCK_LIGHT, material="Concrete"))
    crenellations(folder, cx, base + keep_h + 2.5, cz, 40.0, 16)

    y, r = base + keep_h + 6.0, 22.0
    for i in range(7):
        folder.add(disc("KeepSpire", 6.0, r * 2, (cx, y, cz),
                        color=rgb(70, 34, 30) if i % 2 else ROCK_WARM, material="Slate",
                        yaw=rng.uniform(0, 60)))
        y += 6.0
        r *= 0.75
    gem = ball("SpireGem", (9, 9, 9), (cx, y + 4.0, cz), color=rgb(255, 120, 40),
               material="Neon", cancollide=False, castshadow=False)
    gem.add(glow_light("SpireGlow", brightness=6.0, rng=150))
    gem.add(ember_emitter("SpireEmbers", rate=16, lifetime=(3, 6), speed=(6, 16)))
    folder.add(gem)

    for i in range(3):
        for s in (-1, 1):
            folder.add(part("KeepWindow", (10.0, 16.0, 2.0),
                            (cx + s * 12.0, base + 40.0 + i * 22.0, cz + 31.4),
                            color=rgb(255, 150, 50), material="Neon", transparency=0.1,
                            cancollide=False, castshadow=False, canquery=False))

    gate = lava_slab("GateGlow", (22.0, 24.0, 2.0), (cx, base + 12.0, cz + half + 1.0),
                     color=rgb(255, 120, 30), transparency=0.2)
    gate.add(glow_light("GateLight", brightness=3.0, rng=60))
    folder.add(gate)
    for s in (-1, 1):
        folder.add(lava_slab("KeepLava", (5.0, keep_h, 1.4),
                             (cx + s * 26.0, base + keep_h / 2, cz + 31.6),
                             color=LAVA_CORE, transparency=0.1))
    return folder


# --------------------------------------------------------------------------- #
# bridge
# --------------------------------------------------------------------------- #
def bridge(rng, parent, start, end, width=24.0, deck_y=10.0, arch_height=16.0,
           segments=16):
    folder = Inst("Folder", "Bridge")
    parent.add(folder)
    a, b = Vec3(*start), Vec3(*end)
    span = b - a
    length = math.sqrt(span.x ** 2 + span.z ** 2)
    yaw = math.degrees(math.atan2(-span.x, -span.z))
    rx = math.cos(math.radians(yaw + 90))
    rz = math.sin(math.radians(yaw + 90))

    for i in range(segments):
        tm = (i + 0.5) / segments
        x, z = a.x + span.x * tm, a.z + span.z * tm
        y = deck_y + math.sin(tm * math.pi) * arch_height
        seg_len = length / segments * 1.06
        folder.add(part("Deck", (width, 3.2, seg_len), (x, y, z), rot=(0, yaw, 0),
                        color=ROCK_MID, material="Concrete"))
        for s in (-1, 1):
            folder.add(part("Rail", (1.6, 4.4, seg_len),
                            (x + rx * s * (width / 2 - 1.2), y + 3.6,
                             z + rz * s * (width / 2 - 1.2)),
                            rot=(0, yaw, 0), color=ROCK_DARK, material="Slate",
                            castshadow=False))

    for i in range(1, 5):
        t = i / 5
        x, z = a.x + span.x * t, a.z + span.z * t
        deck = deck_y + math.sin(t * math.pi) * arch_height
        top = deck - 6.0
        h = top + 42.0
        folder.add(disc("Pillar", h, 13.0, (x, top - h / 2, z), color=ROCK_DARK,
                        material="Slate"))
        folder.add(disc("PillarCap", 3.0, 18.0, (x, top, z), color=ROCK_LIGHT,
                        material="Concrete"))
        torch(folder, (x, top + 3.0, z), height=5.0, scale=0.85)

    for s in (-1, 1):
        pts = []
        for i in range(6):
            t = i / 5
            pts.append(Vec3(a.x + span.x * t + rx * s * (width / 2),
                            deck_y + math.sin(t * math.pi) * arch_height + 7.0,
                            a.z + span.z * t + rz * s * (width / 2)))
        for i in range(len(pts) - 1):
            chain(folder, pts[i], pts[i + 1], links=8, sag=0.35, thickness=0.4)

    folder.add(lava_slab("LavaRiver", (width * 0.8, 1.2, length),
                         ((a.x + b.x) / 2, -43.0, (a.z + b.z) / 2), rot=(0, yaw, 0)))
    return folder


# --------------------------------------------------------------------------- #
# lava sea + ambience
# --------------------------------------------------------------------------- #
def lava_sea(rng, parent, size=3000.0, level=-45.0):
    folder = Inst("Folder", "LavaSea")
    parent.add(folder)
    folder.add(lava_slab("LavaBase", (size, 2.0, size), (0, level, 0), color=LAVA_DEEP,
                         transparency=0.0))
    folder.add(lava_slab("LavaBright", (size * 0.99, 2.0, size * 0.99), (0, level + 1.4, 0),
                         color=LAVA_CORE, transparency=0.16))
    folder.add(lava_slab("LavaHot", (size * 0.7, 2.0, size * 0.7), (0, level + 2.6, 0),
                         color=LAVA_HOT, transparency=0.55))

    # cracked crust plates floating on the lava
    for _ in range(150):
        ang = rng.uniform(0, math.tau)
        rad = rng.uniform(90, size * 0.46)
        s = rng.uniform(16, 62)
        folder.add(part("Crust", (s, rng.uniform(0.8, 2.4), s * rng.uniform(0.6, 1.4)),
                        (math.cos(ang) * rad, level + 3.4 + rng.uniform(-0.6, 0.6),
                         math.sin(ang) * rad),
                        rot=(rng.uniform(-4, 4), rng.uniform(0, 360), rng.uniform(-4, 4)),
                        color=rng.choice((ROCK_DEEP, ROCK_DARK, ROCK_MID, ROCK_WARM)),
                        material=rng.choice(("CrackedLava", "Slate", "Basalt")),
                        castshadow=False))

    # warm bounce light + embers over the sea
    for i in range(6):
        ang = i / 6 * math.tau
        rad = size * 0.22
        holder = part("GlowAnchor", (1, 1, 1), (math.cos(ang) * rad, level + 22,
                                               math.sin(ang) * rad),
                      transparency=1.0, cancollide=False, castshadow=False,
                      canquery=False)
        holder.add(glow_light("LavaGlow", brightness=2.4, rng=340))
        holder.add(ember_emitter("SeaEmbers", rate=26, lifetime=(6, 12), speed=(4, 12),
                                 size=(0.5, 1.8), accel=(0, 10, 0)))
        folder.add(holder)

    # drifting smoke columns
    for i, (x, z) in enumerate(((420, -760), (-620, -540), (760, 300), (-320, 640))):
        col = part("SmokeAnchor", (8, 8, 8), (x, -20, z), transparency=1.0,
                   cancollide=False, castshadow=False, canquery=False)
        col.add(smoke_emitter("Smoke", rate=9, lifetime=(12, 22), speed=(4, 12),
                              size=(26, 70)))
        folder.add(col)
    return folder


def horizon(rng, parent):
    """Distant jagged spires + volcano silhouettes for depth."""
    folder = Inst("Folder", "Horizon")
    parent.add(folder)
    for _ in range(46):
        ang = rng.uniform(0, math.tau)
        rad = rng.uniform(700, 1500)
        x, z = math.cos(ang) * rad, math.sin(ang) * rad
        w = rng.uniform(40, 160)
        h = rng.uniform(120, 420)
        folder.add(part("Spire", (w, h, w * rng.uniform(0.6, 1.5)),
                        (x, -45 + h / 2 - h * 0.32, z),
                        rot=(rng.uniform(-5, 5), rng.uniform(0, 360), rng.uniform(-5, 5)),
                        color=rng.choice((ROCK_DEEP, rgb(30, 26, 28))),
                        material="Slate", castshadow=False, cancollide=False,
                        canquery=False))
    # volcano cones on the horizon with lava glows
    for ang, rad, scale in ((0.6, 1150, 1.0), (2.5, 1250, 0.85), (4.2, 1050, 1.2)):
        x, z = math.cos(ang) * rad, math.sin(ang) * rad
        base_y = -45
        for i in range(6):
            t = i / 6
            folder.add(disc("VolcanoTier", 40.0, (420 - i * 62) * scale,
                            (x, base_y + 24 + i * 34, z), color=rng.choice(
                                (ROCK_DEEP, ROCK_DARK)), material="Slate",
                            castshadow=False, cancollide=False))
        crater = part("Crater", (90 * scale, 12, 90 * scale),
                      (x, base_y + 24 + 6 * 34, z), color=LAVA_CORE, material="Neon",
                      transparency=0.1, cancollide=False, castshadow=False, canquery=False)
        crater.add(smoke_emitter("CraterSmoke", rate=14, lifetime=(18, 30), speed=(6, 16),
                                 size=(50, 120)))
        crater.add(glow_light("CraterGlow", brightness=5.0, rng=420))
        folder.add(crater)
    return folder


def floating_debris(rng, parent, count=28, radius=520.0):
    folder = Inst("Folder", "Debris")
    parent.add(folder)
    for _ in range(count):
        ang = rng.uniform(0, math.tau)
        rad = rng.uniform(140, radius)
        s = rng.uniform(6, 22)
        y = rng.uniform(-10, 150)
        folder.add(part("FloatingRock", (s, s * rng.uniform(0.5, 1.1), s * rng.uniform(0.7, 1.3)),
                        (math.cos(ang) * rad, y, math.sin(ang) * rad),
                        rot=(rng.uniform(-25, 25), rng.uniform(0, 360), rng.uniform(-25, 25)),
                        color=rng.choice(ROCK_COLORS),
                        material=rng.choice(("Slate", "Basalt", "Rock")),
                        castshadow=False, cancollide=False, canquery=False))
    return folder


def rain_of_ash(rng, parent, size=1400.0):
    """Ash particles drifting down over the whole arena."""
    folder = Inst("Folder", "Ash")
    parent.add(folder)
    for i in range(6):
        ang = i / 6 * math.tau
        anchor = part("AshAnchor", (10, 10, 10),
                      (math.cos(ang) * size * 0.32, 120, math.sin(ang) * size * 0.32),
                      transparency=1.0, cancollide=False, castshadow=False, canquery=False)
        anchor.add(particles(
            "AshFall", rate=40, lifetime=(14, 22), speed=(2, 5),
            size=[(0.0, 1.4), (1.0, 0.6)],
            color_keys=[(0.0, rgb(150, 132, 126)), (1.0, rgb(60, 50, 48))],
            transparency_keys=[(0.0, 0.35), (0.75, 0.75), (1.0, 1.0)],
            accel=(-1.6, -2.2, 0.8), drag=0.6, spread=(180, 180),
            light_emission=0.0, brightness=0.2, emission_direction="Top"))
        folder.add(anchor)
    return folder


# --------------------------------------------------------------------------- #
# gameplay props
# --------------------------------------------------------------------------- #
def spawn_pad(parent, pos, name="DroneSpawn", radius=16.0, label="СТАРТ"):
    """A metal landing pad with a glowing ring."""
    x, y, z = pos
    pad = disc(name, 1.6, radius * 2, (x, y - 0.8, z), color=rgba_safe((44, 42, 46)),
               material="DiamondPlate")
    parent.add(pad)
    ring = disc("PadRing", 0.7, radius * 2.1, (x, y + 0.05, z), color=CYAN,
                material="Neon", cancollide=False, castshadow=False, transparency=0.15)
    ring.add(glow_light("PadGlow", brightness=2.2, rng=42, color=(90, 220, 255)))
    parent.add(ring)
    for i in range(6):
        ang = i / 6 * math.tau
        lx = x + math.cos(ang) * (radius - 1.6)
        lz = z + math.sin(ang) * (radius - 1.6)
        lamp = part("PadLamp", (2.0, 1.2, 2.0), (lx, y + 0.4, lz), color=CYAN,
                    material="Neon", cancollide=False, castshadow=False)
        parent.add(lamp)
    return pad


def rgba_safe(c):
    return rgb(*c)


def turret_mount(parent, pos, name="TurretMount"):
    """A decorative pedestal the server turns into a live lava turret."""
    x, y, z = pos
    folder = Inst("Folder", name)
    parent.add(folder)
    folder.add(disc("PedestalBase", 3.0, 16.0, (x, y + 1.5, z), color=ROCK_MID,
                    material="Slate"))
    folder.add(disc("PedestalShaft", 9.0, 9.0, (x, y + 7.0, z), color=ROCK_DARK,
                    material="Concrete"))
    head = part("PedestalHead", (7, 5, 7), (x, y + 13.0, z), color=METAL_DARK,
                material="Metal")
    head.add(glow_light("PedestalGlow", brightness=2.0, rng=40))
    folder.add(head)
    return folder


def pickup_anchor(parent, pos, name="PickupAnchor"):
    part_ = part(name, (5, 5, 5), pos, color=CYAN, material="Neon", cancollide=False,
                 castshadow=False, canquery=False, transparency=1.0)
    parent.add(part_)
    return part_


def beacon_pillar(parent, pos, name="BeaconPillar"):
    x, y, z = pos
    folder = Inst("Folder", name)
    parent.add(folder)
    folder.add(disc("PillarCore", 40.0, 6.0, (x, y + 20, z), color=ROCK_MID,
                    material="Concrete"))
    crown = part("PillarCrown", (5, 5, 5), (x, y + 42, z), color=LAVA_HOT,
                 material="Neon", cancollide=False, castshadow=False)
    crown.add(glow_light("CrownGlow", brightness=4.0, rng=90))
    crown.add(ember_emitter("CrownEmbers", rate=10, lifetime=(2, 5), speed=(4, 10)))
    folder.add(crown)
    return folder
