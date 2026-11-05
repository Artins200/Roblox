#!/usr/bin/env python3
"""
maps.py -- генератор карт. Каждая карта -- это Model с именем-идентификатором
и четырьмя папками-контрактами, которые ждёт сервер:

    Geometry        -- вся статика уровня
    SpawnPads       -- площадки появления дронов (Part)
    SurvivorSpawns  -- точки появления выживших (Part)
    BotSpawns       -- точки появления ИИ-ботов (Part)

Карты:
    lava     -- «Лавовый каньон»  (берётся из arena.py)
    desert   -- «Песчаные руины»
    ice      -- «Ледяные шпили»
    space    -- «Орбитальная станция»
"""

import math
import random

from rbxlx import Inst, Vec3, cf, rgb, part as _part

import arena

TAU = math.tau


# --------------------------------------------------------------------------- #
# примитивы
# --------------------------------------------------------------------------- #
def p(name, size, pos, rot=None, color=(90, 90, 96), mat="Concrete", **kw):
    kw.setdefault("anchored", True)
    kw.setdefault("canquery", True)
    return _part(name, size, pos, rot, color=color, material=mat, **kw)


def glow(name, size, pos, rot=None, color=(255, 150, 60), transparency=0.0,
         light=(6.0, 60.0), shape="Block"):
    """Неоновая деталь со своим источником света."""
    inst = p(name, size, pos, rot, color=color, mat="Neon", transparency=transparency,
             cancollide=False, castshadow=False, shape=shape)
    if light:
        inst.add(p_light("Glow", color, light[0], light[1]))
    return inst


def p_light(name, color, brightness, rng, shadows=False):
    from rbxlx import point_light
    return point_light(None, color=color, brightness=brightness, rng=rng,
                       shadows=shadows, name=name)


def disc(name, height, diameter, pos, color=(60, 60, 66), mat="Concrete",
         transparency=0.0, cancollide=True, castshadow=True, yaw=0.0):
    from rbxlx import cylinder
    return cylinder(name, (height, diameter, diameter), pos, (0.0, yaw, 90.0),
                    color=color, material=mat, transparency=transparency,
                    cancollide=cancollide, castshadow=castshadow, canquery=cancollide)


def emitter(name, bounds, pos, **kw):
    """Невидимая деталь-носитель для фоновых частиц."""
    holder = p(name, bounds, pos, color=(255, 255, 255), mat="SmoothPlastic",
               transparency=1.0, cancollide=False, canquery=False, castshadow=False)
    from rbxlx import particles
    holder.add(particles(name + "FX", **kw))
    return holder


def pad(parent, pos, color=(120, 225, 255), name="DroneSpawn", radius=15.0):
    """Площадка спавна дрона: металлический диск + неоновое кольцо + лучи."""
    x, y, z = pos
    base = disc(name, 1.5, radius * 2, (x, y - 0.75, z), color=(52, 50, 56),
                mat="DiamondPlate")
    parent.add(base)
    ring = disc("Ring", 0.6, radius * 2.15, (x, y + 0.1, z), color=color, mat="Neon",
                cancollide=False, castshadow=False, transparency=0.05)
    ring.add(p_light("RingGlow", color, 3.0, radius * 3.2))
    parent.add(ring)
    for i in range(4):
        ang = i / 4 * TAU + math.pi / 4
        lx = x + math.cos(ang) * (radius - 2.2)
        lz = z + math.sin(ang) * (radius - 2.2)
        parent.add(p("Lamp", (2.4, 1.4, 2.4), (lx, y + 0.5, lz), color=color,
                     mat="Neon", cancollide=False, castshadow=False))
    # луч вверх, чтобы площадку было видно с высоты
    beam = p("Beam", (1.6, 60, 1.6), (x, y + 30, z), color=color, mat="Neon",
             transparency=0.9, cancollide=False, castshadow=False, canquery=False)
    parent.add(beam)
    return base


def spawn_point(parent, pos, color=(255, 220, 120), name="SurvivorSpawn", radius=6.0):
    x, y, z = pos
    plate = disc(name, 0.5, radius * 2, (x, y + 0.25, z), color=color, mat="Neon",
                 cancollide=False, castshadow=False, transparency=0.35)
    plate.add(p_light("SpawnGlow", color, 1.6, 22))
    parent.add(plate)
    return plate


def neon_strip(parent, size, pos, rot=None, color=(120, 225, 255)):
    parent.add(p("Strip", size, pos, rot, color=color, mat="Neon",
                 cancollide=False, castshadow=False, canquery=False))


# --------------------------------------------------------------------------- #
# строительные блоки
# --------------------------------------------------------------------------- #
def building(rng, parent, x, z, w, d, h, body=(180, 160, 140), trim=(120, 225, 255),
             floors=2, door=1, mat="Concrete", y=0.0):
    """Коробка-здание: стены с проёмами, этажи, неоновая подсветка, крыша."""
    t = 1.4
    folder = Inst("Folder", "Building")
    parent.add(folder)
    base_y = y + h / 2
    # пол и перекрытия
    folder.add(p("Floor", (w, t, d), (x, y + t / 2, z), color=(60, 58, 62), mat="Concrete"))
    for f in range(1, floors):
        fy = y + h * f / floors
        folder.add(p("Deck", (w - 2, 0.8, d - 2), (x, fy, z), color=(74, 70, 74),
                     mat="Concrete"))
    # стены (4 стороны), у одной -- дверной проём
    yaw = 0.0
    for side in range(4):
        cx = x + math.cos(side * math.pi / 2) * (w / 2 if side in (0, 2) else 0)
        cz = z + math.sin(side * math.pi / 2) * (d / 2 if side in (1, 3) else 0)
        horizontal = side in (1, 3)
        length = (d if horizontal else w)
        thickness = t
        size = (length, h, thickness) if horizontal else (thickness, h, length)
        if side == door:
            # проём шириной 8
            seg = (length - 8) / 2
            for s in (-1, 1):
                off = (seg + 8) / 2 * s
                pos = ((cx + off) if horizontal else cx, base_y,
                       (cz if horizontal else cz + off))
                ssize = (seg, h, thickness) if horizontal else (thickness, h, seg)
                folder.add(p("Wall", ssize, pos, color=body, mat=mat))
        else:
            folder.add(p("Wall", size, (cx, base_y, cz), color=body, mat=mat))
        # окна-неон
        wy = y + h * 0.62
        for k in (-1, 1):
            off = k * length * 0.28
            wx = (cx + off) if horizontal else cx
            wz = cz if horizontal else (cz + off)
            neon_strip(folder, (6 if horizontal else 0.4, 1.6, 0.4 if horizontal else 6),
                       (wx, wy, wz), color=trim)
    # крыша
    folder.add(p("Roof", (w + 1.6, 1.0, d + 1.6), (x, y + h + 0.5, z),
                 color=(52, 50, 54), mat="Concrete"))
    neon_strip(folder, (w + 2, 0.5, 0.5), (x, y + h + 1.1, z + d / 2), color=trim)
    neon_strip(folder, (w + 2, 0.5, 0.5), (x, y + h + 1.1, z - d / 2), color=trim)
    return folder


def crates(rng, parent, center, count=6, size=(6, 6, 6)):
    x, y, z = center
    for i in range(count):
        s = rng.uniform(0.7, 1.5)
        pos = (x + rng.uniform(-16, 16), y + size[1] * s / 2 + i * 0.0,
               z + rng.uniform(-16, 16))
        parent.add(p("Crate", (size[0] * s, size[1] * s, size[2] * s), pos,
                     rot=(0, rng.uniform(0, 360), 0),
                     color=rng.choice(((122, 86, 52), (98, 68, 42), (150, 112, 66))),
                     mat="WoodPlanks"))


def barrels(rng, parent, center, count=4, color=(90, 120, 80)):
    x, y, z = center
    for i in range(count):
        pos = (x + rng.uniform(-10, 10), y + 3, z + rng.uniform(-10, 10))
        b = disc("Barrel", 6.0, 4.4, pos, color=color, mat="Metal")
        parent.add(b)


def rubble(rng, parent, center, count=8, color=(120, 112, 100)):
    x, y, z = center
    for i in range(count):
        s = rng.uniform(2.0, 7.0)
        parent.add(p("Rubble", (s, s * rng.uniform(0.4, 0.9), s),
                     (x + rng.uniform(-22, 22), y + s * 0.3, z + rng.uniform(-22, 22)),
                     rot=(rng.uniform(-20, 20), rng.uniform(0, 360), rng.uniform(-20, 20)),
                     color=color, mat="Slate"))


# --------------------------------------------------------------------------- #
# карта 1: лавовый каньон (готовая арена)
# --------------------------------------------------------------------------- #
def build_lava(seed=20260101):
    rng = random.Random(seed)
    model = Inst("Model", "lava")
    geometry, _gameplay = arena.build_arena(seed=seed)
    model.add(geometry)

    pads = Inst("Folder", "SpawnPads")
    surv = Inst("Folder", "SurvivorSpawns")
    bots = Inst("Folder", "BotSpawns")
    model.add(pads, surv, bots)

    # дроновые площадки высоко над островом
    for i, (x, y, z) in enumerate(((0, 96, 0), (110, 120, -60), (-110, 120, -60),
                                   (0, 132, 96), (-84, 104, 84), (84, 104, 84))):
        pad(pads, (x, y, z), color=(120, 225, 255), name="DroneSpawn%d" % (i + 1))

    # выжившие -- на центральном острове и у моста
    spots = [(0, 2, 0), (18, 2, 14), (-18, 2, 14), (26, 2, -18), (-26, 2, -18),
             (0, 2, -46), (0, 2, -70), (44, 2, 0), (-44, 2, 0), (0, 2, 40),
             (60, 2, 60), (-60, 2, 60)]
    for i, (x, y, z) in enumerate(spots):
        spawn_point(surv, (x, y + 1.0, z), color=(255, 210, 130),
                    name="SurvivorSpawn%d" % (i + 1))

    for i, (x, y, z) in enumerate(((60, 4, 60), (-60, 4, 60), (0, 4, -100),
                                   (90, 4, -30), (-90, 4, -30), (0, 4, 120),
                                   (0, 60, 0), (120, 70, 40), (-120, 70, 40))):
        spawn_point(bots, (x, y, z), color=(255, 96, 96), name="BotSpawn%d" % (i + 1))
    return model


# --------------------------------------------------------------------------- #
# карта 2: песчаные руины
# --------------------------------------------------------------------------- #
def build_desert(seed=77001):
    rng = random.Random(seed)
    model = Inst("Model", "desert")
    geo = Inst("Folder", "Geometry")
    model.add(geo)

    SAND = (226, 192, 138)
    SAND_DARK = (198, 162, 112)
    STONE = (196, 168, 128)
    STONE_DARK = (156, 128, 94)
    GOLD = (255, 196, 96)
    TURQ = (96, 226, 214)

    # земля: огромная песчаная плита + плиты-дюны
    geo.add(p("Dune", (2200, 60, 2200), (0, -30, 0), color=SAND, mat="Sand"))
    for i in range(26):
        ang = rng.uniform(0, TAU)
        r = rng.uniform(90, 980)
        geo.add(p("DuneRidge", (rng.uniform(120, 300), rng.uniform(10, 26),
                                rng.uniform(120, 300)),
                  (math.cos(ang) * r, -8, math.sin(ang) * r),
                  rot=(0, rng.uniform(0, 360), 0),
                  color=rng.choice((SAND, SAND_DARK)), mat="Sand", castshadow=False))

    # месы (ступенчатые плато) -- вертикальность для дронов
    mesa_spots = [(300, 240, 118), (-330, 260, 150), (420, -300, 96),
                  (-380, -280, 132), (60, -470, 168), (-120, 470, 110)]
    for i, (x, z, h) in enumerate(mesa_spots):
        tiers = rng.randint(3, 5)
        for t in range(tiers):
            frac = 1.0 - t / tiers
            geo.add(disc("Mesa", h / tiers, 210 * frac + 40,
                         (x, (t + 0.5) * h / tiers, z),
                         color=rng.choice((STONE, STONE_DARK, SAND_DARK)), mat="Sandstone"))
        top = h + 2
        geo.add(disc("MesaTop", 3.0, 96, (x, top, z), color=STONE, mat="Concrete"))
        neon_strip(geo, (70, 0.6, 0.6), (x, top + 2.2, z + 42), color=TURQ)
        neon_strip(geo, (70, 0.6, 0.6), (x, top + 2.2, z - 42), color=TURQ)
        pad(folder_of(geo), (x, top + 6, z), color=TURQ, name="Pad%d" % i)

    # мёртвый город: кварталы полуразрушенных домов
    for i in range(16):
        ang = i / 16 * TAU + rng.uniform(-0.16, 0.16)
        r = rng.uniform(120, 560)
        x, z = math.cos(ang) * r, math.sin(ang) * r
        w = rng.uniform(28, 58)
        d = rng.uniform(28, 58)
        h = rng.uniform(26, 86)
        building(rng, geo, x, z, w, d, h, body=rng.choice((STONE, STONE_DARK, SAND_DARK)),
                 trim=rng.choice((GOLD, TURQ)), floors=rng.randint(2, 4),
                 door=rng.randint(0, 3), mat="Sandstone")
        if i % 3 == 0:
            crates(rng, geo, (x + rng.uniform(-40, 40), 0, z + rng.uniform(-40, 40)), 4)
            barrels(rng, geo, (x + rng.uniform(-46, 46), 0, z + rng.uniform(-46, 46)), 3,
                    color=rng.choice(((96, 116, 72), (120, 92, 60))))

    # рухнувшие колонны и арки
    for i in range(14):
        ang = rng.uniform(0, TAU)
        r = rng.uniform(100, 520)
        x, z = math.cos(ang) * r, math.sin(ang) * r
        h = rng.uniform(18, 44)
        geo.add(disc("Column", h, rng.uniform(6, 11), (x, h / 2, z),
                     color=STONE, mat="Sandstone"))
        if rng.random() < 0.5:
            geo.add(p("Capital", (14, 3, 14), (x, h + 1, z), color=STONE_DARK, mat="Sandstone"))
    for i in range(4):
        ang = i / 4 * TAU
        r = 300
        x, z = math.cos(ang) * r, math.sin(ang) * r
        for s in (-1, 1):
            geo.add(disc("ArchPillar", 60, 12, (x + s * 20, 30, z), color=STONE,
                         mat="Sandstone"))
        geo.add(p("ArchTop", (56, 8, 14), (x, 62, z), color=STONE_DARK, mat="Sandstone"))
        neon_strip(geo, (44, 0.8, 0.8), (x, 66.6, z), color=GOLD)

    # сухие деревья
    for i in range(20):
        ang = rng.uniform(0, TAU)
        r = rng.uniform(90, 620)
        x, z = math.cos(ang) * r, math.sin(ang) * r
        h = rng.uniform(16, 30)
        geo.add(disc("Trunk", h, 3.0, (x, h / 2, z), color=(96, 72, 48), mat="Wood"))
        for b in range(3):
            byaw = rng.uniform(0, 360)
            blen = rng.uniform(8, 14)
            geo.add(p("Branch", (1.4, blen, 1.4),
                      (x + math.cos(math.radians(byaw)) * blen * 0.4,
                       h * 0.8, z + math.sin(math.radians(byaw)) * blen * 0.4),
                      rot=(rng.uniform(30, 60), byaw, 0), color=(88, 66, 44), mat="Wood"))

    # пыль
    geo.add(emitter("SandDust", (1500, 10, 1500), (0, 6, 0), rate=90.0,
                    lifetime=(4.0, 9.0), speed=(6.0, 20.0), size=(1.2, 3.4),
                    color_keys=[(0.0, rgb(232, 206, 160)), (1.0, rgb(190, 160, 118))],
                    transparency_keys=[(0.0, 0.85), (1.0, 1.0)],
                    accel=(6, 1, 0), spread=(180.0, 180.0), light_emission=0.0,
                    emission_direction="Top"))

    pads = Inst("Folder", "SpawnPads")
    surv = Inst("Folder", "SurvivorSpawns")
    bots = Inst("Folder", "BotSpawns")
    model.add(pads, surv, bots)

    for i, (x, z, h) in enumerate(mesa_spots):
        pad(pads, (x, h + 46, z), color=TURQ, name="DroneSpawn%d" % (i + 1))
    for i, (x, y, z) in enumerate(((0, 20, 0), (-70, 20, 90), (70, 20, -90),
                                   (0, 150, -30), (180, 20, 180), (-180, 20, -180))):
        pad(pads, (x, y, z), color=GOLD, name="HighPad%d" % (i + 1))

    gh = math.sqrt(1200)
    spots = [(0, 1, 0), (34, 1, 0), (-34, 1, 0), (0, 1, 34), (0, 1, -34),
             (110, 1, 60), (-110, 1, 60), (110, 1, -60), (-110, 1, -60),
             (200, 1, 0), (-200, 1, 0), (0, 1, 200)]
    for i, (x, y, z) in enumerate(spots):
        spawn_point(surv, (x, y, z), color=(255, 214, 130),
                    name="SurvivorSpawn%d" % (i + 1))
    for i, (x, z) in enumerate(((60, 60), (-60, 60), (60, -60), (-60, -60),
                                 (260, 260), (-260, 260), (260, -260), (-260, -260))):
        spawn_point(bots, (x, 1, z), color=(255, 96, 96), name="BotSpawn%d" % (i + 1))
    return model


def folder_of(parent):
    """Площадки кладутся в отдельную папку -- обёртка для мес."""
    return parent


# --------------------------------------------------------------------------- #
# карта 3: ледяные шпили
# --------------------------------------------------------------------------- #
def build_ice(seed=33011):
    rng = random.Random(seed)
    model = Inst("Model", "ice")
    geo = Inst("Folder", "Geometry")
    model.add(geo)

    ICE = (206, 236, 248)
    ICE_DEEP = (150, 196, 224)
    ICE_DARK = (110, 150, 186)
    SNOW = (244, 250, 255)
    NEON = (110, 220, 255)
    CYAN = (150, 255, 250)

    # замёрзшее озеро
    geo.add(p("IceField", (2400, 40, 2400), (0, -20, 0), color=ICE_DEEP,
              mat="Glass", transparency=0.25, reflectance=0.35))
    geo.add(p("IceCore", (2400, 10, 2400), (0, -44, 0), color=(26, 60, 96), mat="Ice"))
    for i in range(30):
        ang = rng.uniform(0, TAU)
        r = rng.uniform(120, 1000)
        geo.add(disc("Floe", 2.4, rng.uniform(40, 130),
                     (math.cos(ang) * r, 0.6, math.sin(ang) * r),
                     color=rng.choice((ICE, SNOW)), mat="Ice",
                     transparency=0.12, yaw=rng.uniform(0, 360)))

    # ледяные шпили
    for i in range(22):
        ang = rng.uniform(0, TAU)
        r = rng.uniform(120, 780)
        x, z = math.cos(ang) * r, math.sin(ang) * r
        h = rng.uniform(70, 240)
        base = rng.uniform(18, 40)
        seg = 4
        for s in range(seg):
            frac = 1.0 - s / seg
            geo.add(disc("Spire", h / seg, base * frac + 4,
                         (x, (s + 0.5) * h / seg, z),
                         color=rng.choice((ICE, ICE_DEEP, ICE_DARK)), mat="Ice",
                         transparency=0.05))
        tip = p("SpireTip", (8, 14, 8), (x, h + 6, z), color=CYAN, mat="Neon",
                cancollide=False, castshadow=False)
        tip.add(p_light("Tip", CYAN, 2.4, 60))
        geo.add(tip)

    # кристаллы-кластеры
    for i in range(28):
        ang = rng.uniform(0, TAU)
        r = rng.uniform(80, 900)
        x, z = math.cos(ang) * r, math.sin(ang) * r
        for k in range(rng.randint(3, 6)):
            h = rng.uniform(10, 34)
            geo.add(p("Crystal", (3.2, h, 3.2),
                      (x + rng.uniform(-8, 8), h / 2, z + rng.uniform(-8, 8)),
                      rot=(rng.uniform(-24, 24), rng.uniform(0, 360), rng.uniform(-24, 24)),
                      color=NEON, mat="Neon", transparency=0.15, castshadow=False))

    # заброшенная станция: три блока и антенна
    for i, (x, z, w, d, h) in enumerate(((180, 180, 60, 40, 34),
                                          (240, 150, 44, 34, 26),
                                          (150, 250, 36, 36, 20))):
        building(rng, geo, x, z, w, d, h, body=(212, 226, 236), trim=NEON,
                 floors=2, door=i % 4, mat="Metal")
        neon_strip(geo, (w + 2, 0.6, 0.6), (x, h + 1.4, z + d / 2), color=CYAN)

    geo.add(disc("AntennaMast", 90, 5, (180, 75, 180), color=(120, 132, 142), mat="Metal"))
    for s in range(4):
        geo.add(p("AntennaRing", (26 - s * 4, 0.8, 26 - s * 4), (180, 46 + s * 12, 180),
                  color=NEON, mat="Neon", cancollide=False, castshadow=False))
    geo.add(glow("AntennaTip", (6, 6, 6), (180, 124, 180), color=(255, 90, 90),
                 light=(7.0, 110.0), shape="Ball"))

    # деревянные мостки между площадками
    bridges = [((0, 6, 0), (180, 6, 180)), ((-160, 8, 140), (0, 6, 0)),
               ((0, 6, 0), (140, 8, -190)), ((-190, 8, -120), (0, 6, 0))]
    for (ax, ay, az), (bx, by, bz) in bridges:
        length = math.hypot(bx - ax, bz - az)
        yaw = math.degrees(math.atan2(-(bx - ax), -(bz - az))) + 90
        geo.add(p("Walkway", (10, 1.6, length), ((ax + bx) / 2, (ay + by) / 2, (az + bz) / 2),
                  rot=(0, yaw, 0), color=(96, 74, 50), mat="WoodPlanks"))
        for k in (-1, 1):
            off = 6
            geo.add(p("Railing", (0.6, 4, length),
                      ((ax + bx) / 2 + math.cos(math.radians(yaw)) * off, (ay + by) / 2 + 3,
                       (az + bz) / 2 - math.sin(math.radians(yaw)) * off),
                      rot=(0, yaw, 0), color=(120, 92, 62), mat="WoodPlanks",
                      cancollide=False))

    # центральная арена-платформа
    geo.add(disc("Plaza", 6, 300, (0, 3, 0), color=ICE, mat="Ice", transparency=0.1))
    geo.add(disc("PlazaRing", 0.8, 320, (0, 6.4, 0), color=CYAN, mat="Neon",
                 cancollide=False, castshadow=False, transparency=0.2))

    # снег и метель
    geo.add(emitter("Snow", (1800, 400, 1800), (0, 220, 0), rate=320.0,
                    lifetime=(6.0, 12.0), speed=(8.0, 20.0), size=(0.8, 1.8),
                    color_keys=[(0.0, rgb(255, 255, 255)), (1.0, rgb(200, 230, 255))],
                    transparency_keys=[(0.0, 0.35), (1.0, 0.9)],
                    accel=(4, -3, 2), spread=(180.0, 180.0), light_emission=0.0,
                    emission_direction="Bottom"))

    pads = Inst("Folder", "SpawnPads")
    surv = Inst("Folder", "SurvivorSpawns")
    bots = Inst("Folder", "BotSpawns")
    model.add(pads, surv, bots)

    for i, (x, y, z) in enumerate(((0, 40, 0), (160, 70, 0), (-160, 70, 0),
                                    (0, 70, 160), (0, 70, -160), (330, 100, 330),
                                    (-330, 100, -330))):
        pad(pads, (x, y, z), color=CYAN, name="DroneSpawn%d" % (i + 1))

    spots = [(0, 7, 40), (0, 7, -40), (40, 7, 0), (-40, 7, 0), (180, 7, 180),
             (240, 7, 150), (150, 7, 250), (110, 7, 110), (-120, 7, -120),
             (-180, 7, -140), (120, 7, -180), (-150, 7, 220)]
    for i, (x, y, z) in enumerate(spots):
        spawn_point(surv, (x, y, z), color=(190, 240, 255),
                    name="SurvivorSpawn%d" % (i + 1))
    for i, (x, z) in enumerate(((60, 60), (-60, 60), (60, -60), (-60, -60),
                                 (200, 60), (-200, 60), (60, 200), (60, -200))):
        spawn_point(bots, (x, 7, z), color=(255, 96, 96), name="BotSpawn%d" % (i + 1))
    return model


# --------------------------------------------------------------------------- #
# карта 4: орбитальная станция
# --------------------------------------------------------------------------- #
def build_space(seed=90210):
    rng = random.Random(seed)
    model = Inst("Model", "space")
    geo = Inst("Folder", "Geometry")
    model.add(geo)

    HULL = (58, 60, 72)
    HULL_LIGHT = (96, 100, 116)
    NEON = (140, 120, 255)
    NEON2 = (90, 230, 255)
    WARN = (255, 170, 60)

    # центральный хаб
    geo.add(disc("HubFloor", 8, 420, (0, 0, 0), color=HULL, mat="DiamondPlate"))
    geo.add(disc("HubTrim", 0.8, 450, (0, 4.6, 0), color=NEON, mat="Neon",
                 cancollide=False, castshadow=False, transparency=0.1))
    hub = disc("HubCore", 40, 90, (0, 26, 0), color=HULL_LIGHT, mat="Metal")
    geo.add(hub)
    core = glow("Reactor", (54, 54, 54), (0, 56, 0), color=NEON2, light=(9.0, 220.0),
                shape="Ball", transparency=0.25)
    geo.add(core)
    for ring in range(3):
        geo.add(p("ReactorRing", (76 - ring * 8, 1.6, 76 - ring * 8), (0, 44 + ring * 14, 0),
                  color=NEON, mat="Neon", cancollide=False, castshadow=False))

    # кольцо станции: сегменты по кругу + стыки
    segments = 26
    for i in range(segments):
        ang = i / segments * TAU
        x, z = math.cos(ang) * 520, math.sin(ang) * 520
        yaw = math.degrees(-ang)
        geo.add(p("RingSegment", (120, 10, 44), (x, 0, z), rot=(0, yaw, 0),
                  color=HULL, mat="DiamondPlate"))
        if i % 4 == 0:
            geo.add(p("RingNode", (56, 26, 56), (x, 14, z), rot=(0, yaw, 0),
                      color=HULL_LIGHT, mat="Metal"))
            neon_strip(geo, (56, 0.8, 0.8), (x, 27.4, z), color=NEON2)
            geo.add(glow("NodeBeacon", (3, 3, 3), (x, 30, z), color=WARN,
                         light=(4.0, 60.0), shape="Ball"))
        neon_strip(geo, (118, 0.5, 0.5), (x, 5.4, z + 0), color=NEON)

    # спицы от хаба к кольцу
    for i in range(4):
        ang = i / 4 * TAU + math.pi / 8
        x, z = math.cos(ang) * 260, math.sin(ang) * 260
        yaw = math.degrees(-ang)
        geo.add(p("Spoke", (60, 6, 470), (x, 0, z), rot=(0, yaw + 90, 0),
                  color=HULL, mat="DiamondPlate"))
        neon_strip(geo, (52, 0.6, 430), (x, 3.4, z), rot=(0, yaw + 90, 0), color=NEON)

    # модули-цилиндры
    module_spots = [(720, 60, 76), (-700, 60, 76), (120, 220, 70), (-140, 230, 66),
                    (760, -420, 84), (-760, -380, 84), (0, -760, 74), (0, 700, 74)]
    for i, (x, z, y) in enumerate(module_spots):
        yaw = rng.uniform(0, 360)
        geo.add(disc("ModuleBody", 96, 34, (x, y, z), color=HULL_LIGHT, mat="Metal",
                     yaw=yaw))
        geo.add(disc("ModuleCap", 5, 40, (x, y + 48, z), color=HULL, mat="Metal", yaw=yaw))
        geo.add(disc("ModuleCapLow", 5, 40, (x, y - 48, z), color=HULL, mat="Metal", yaw=yaw))
        for s in range(3):
            neon_strip(geo, (0.7, 1.4, 32), (x + rng.uniform(-14, 14), y + s * 24 - 24,
                                            z + rng.uniform(-14, 14)),
                       rot=(0, yaw, 0), color=NEON2)
        # площадка на модуле
        geo.add(disc("ModuleDeck", 4, 70, (x, y + 54, z), color=HULL, mat="DiamondPlate"))

    # солнечные панели
    for i in range(10):
        ang = rng.uniform(0, TAU)
        r = rng.uniform(200, 780)
        x, z = math.cos(ang) * r, math.sin(ang) * r
        y = rng.uniform(60, 220)
        yaw = rng.uniform(0, 360)
        geo.add(p("SolarMast", (4, 40, 4), (x, y - 24, z), color=HULL_LIGHT, mat="Metal"))
        geo.add(p("SolarPanel", (120, 1.6, 64), (x, y, z), rot=(0, yaw, 0),
                  color=(28, 40, 96), mat="Metal", reflectance=0.4))
        for k in range(5):
            neon_strip(geo, (116, 0.4, 1.2), (x, y + 0.9, z - 26 + k * 13),
                       rot=(0, yaw, 0), color=(80, 120, 255))

    # обломки в пустоте
    for i in range(40):
        ang = rng.uniform(0, TAU)
        r = rng.uniform(300, 1200)
        s = rng.uniform(4, 22)
        geo.add(p("Debris", (s, s * rng.uniform(0.3, 1.0), s * rng.uniform(0.4, 1.2)),
                  (math.cos(ang) * r, rng.uniform(-160, 260), math.sin(ang) * r),
                  rot=(rng.uniform(0, 360), rng.uniform(0, 360), rng.uniform(0, 360)),
                  color=HULL, mat="Metal", castshadow=False))

    # далёкая «звезда» и туманность
    star = glow("DistantStar", (240, 240, 240), (2600, 600, -2600), color=(255, 250, 220),
                light=None, shape="Ball", transparency=0.05)
    geo.add(star)
    geo.add(emitter("SpaceDust", (2400, 800, 2400), (0, 200, 0), rate=140.0,
                    lifetime=(8.0, 16.0), speed=(1.0, 5.0), size=(0.5, 1.4),
                    color_keys=[(0.0, rgb(180, 210, 255)), (1.0, rgb(120, 140, 255))],
                    transparency_keys=[(0.0, 0.2), (1.0, 0.95)],
                    accel=(0, 0.4, 0), spread=(180.0, 180.0), light_emission=0.8,
                    emission_direction="Top"))

    pads = Inst("Folder", "SpawnPads")
    surv = Inst("Folder", "SurvivorSpawns")
    bots = Inst("Folder", "BotSpawns")
    model.add(pads, surv, bots)

    for i in range(8):
        ang = i / 8 * TAU
        x, z = math.cos(ang) * 520, math.sin(ang) * 520
        pad(pads, (x, 40, z), color=NEON, name="DroneSpawn%d" % (i + 1))
    pad(pads, (0, 120, 0), color=NEON2, name="HubPad")

    spots = [(-60, 6, -60), (60, 6, -60), (-60, 6, 60), (60, 6, 60), (0, 6, -140),
             (0, 6, 140), (-140, 6, 0), (140, 6, 0), (300, 8, 300), (-300, 8, -300),
             (300, 8, -300), (-300, 8, 300)]
    for i, (x, y, z) in enumerate(spots):
        spawn_point(surv, (x, y, z), color=NEON2, name="SurvivorSpawn%d" % (i + 1))
    for i in range(8):
        ang = i / 8 * TAU
        spawn_point(bots, (math.cos(ang) * 300, 8, math.sin(ang) * 300),
                    color=(255, 96, 96), name="BotSpawn%d" % (i + 1))
    return model


BUILDERS = {
    "lava": build_lava,
    "desert": build_desert,
    "ice": build_ice,
    "space": build_space,
}


def build_all(seed=None):
    maps = []
    for map_id, fn in BUILDERS.items():
        maps.append(fn() if seed is None else fn(seed))
    return maps
