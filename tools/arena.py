"""
arena.py -- сборка арены «Лавовый каньон»: острова, замок, мост, лава,
таблички, площадки спавна, турели и бонусы.

Всё статичное: после сборки .rbxlx открывается в Studio и сразу выглядит
как готовый уровень (движок поднимает только живые объекты -- врагов,
турели, бонусы).
"""

import math
import random

from rbxlx import CF, Inst, Vec3, cf, rgb
import volcano_map as M


def face_yaw(dx, dz):
    """Поворот (в градусах), при котором -Z детали смотрит на (dx, dz)."""
    return math.degrees(math.atan2(-dx, -dz))


def pillar_platform(rng, parent, x, z, top_y, radius=14.0, height=46.0):
    """Каменный столб с плоской площадкой сверху (под турель)."""
    folder = Inst("Folder", "Pillar")
    parent.add(folder)
    h = height
    folder.add(M.disc("PillarShaft", h, radius * 2, (x, top_y - h / 2, z),
                      color=rng.choice((M.ROCK_DARK, M.ROCK_MID)), material="Slate"))
    folder.add(M.disc("PillarTop", 3.0, radius * 2.3, (x, top_y - 1.0, z),
                      color=M.ROCK_LIGHT, material="Concrete"))
    folder.add(M.disc("PillarBase", 5.0, radius * 2.1, (x, top_y - h + 2.5, z),
                      color=M.ROCK_DEEP, material="Basalt"))
    for _ in range(6):
        ang = rng.uniform(0, math.tau)
        folder.add(M.part("Chunk", (rng.uniform(3, 8), rng.uniform(3, 9), rng.uniform(3, 8)),
                          (x + math.cos(ang) * radius, top_y - h * rng.uniform(0.2, 0.9),
                           z + math.sin(ang) * radius),
                          rot=(rng.uniform(-10, 10), rng.uniform(0, 360), rng.uniform(-10, 10)),
                          color=rng.choice(M.ROCK_COLORS), material="Slate",
                          castshadow=False))
    return folder


def stairs(parent, start, end, width=40.0, steps=6, color=None, material="Concrete"):
    """Каменная лестница между двумя уровнями (для подъёма к мосту)."""
    sx, sy, sz = start
    ex, ey, ez = end
    color = color or M.ROCK_MID
    folder = Inst("Folder", "Stairs")
    parent.add(folder)
    yaw = face_yaw(ex - sx, ez - sz)
    dz = (ez - sz) / steps
    dy = (ey - sy) / steps
    for i in range(steps):
        folder.add(M.part("Step", (width, abs(dy) + 2.0, abs(dz) + 2.0),
                          (sx, sy + dy * (i + 0.5), sz + dz * (i + 0.5)),
                          rot=(0, yaw, 0), color=color, material=material))
    return folder


def build_arena(seed=20260101):
    rng = random.Random(seed)
    map_root = Inst("Folder", "VolcanoMap")
    gameplay = Inst("Folder", "Gameplay")
    spawn_pads = Inst("Folder", "SpawnPads")
    turret_mounts = Inst("Folder", "TurretMounts")
    pickup_anchors = Inst("Folder", "PickupAnchors")
    signs = Inst("Folder", "Signs")

    # ------------------------------------------------------------- лава и небо
    M.lava_sea(rng, map_root)
    M.horizon(rng, map_root)
    M.floating_debris(rng, map_root, count=30)
    M.rain_of_ash(rng, map_root)

    # ------------------------------------------------------------- центральный остров
    M.island(rng, map_root, (0, 0, 0), 92.0, depth=96.0, rocks=42, edge_rocks=38,
             lava_rim=True, torches=4, name="CentralIsland", falls=3)

    # терраса и лестница к мосту
    stairs(map_root, (0, 0, -52), (0, 18, -96), width=44, steps=6)

    # ------------------------------------------------------------- мост к замку
    M.bridge(rng, map_root, (0, 18, -100), (0, 18, -284), width=26, deck_y=18,
             arch_height=15, segments=18)

    # ------------------------------------------------------------- замок
    M.castle(rng, map_root, (0, 18, -432), 18.0)

    # ------------------------------------------------------------- кольцевые острова
    ring_islands = []
    ring_defs = [
        (22, 250, 46, 8), (72, 300, 38, 22), (128, 268, 52, 2),
        (188, 312, 40, 26), (236, 246, 44, -4), (296, 322, 36, 14),
        (340, 260, 48, 4),
    ]
    for i, (ang, dist, rad, top) in enumerate(ring_defs):
        x = math.cos(math.radians(ang)) * dist
        z = math.sin(math.radians(ang)) * dist
        isl = M.island(rng, map_root, (x, top, z), rad, depth=78.0,
                       rocks=max(16, int(rad * 0.5)), edge_rocks=max(14, int(rad * 0.42)),
                       lava_rim=True, torches=2, name="Island2" if i % 2 else "Island1",
                       falls=2)
        ring_islands.append((x, top, z, rad))

        # иногда вешаем цепь до центрального острова
        if i in (0, 3, 5):
            M.chain(map_root, (x * 0.55, top + 12, z * 0.55),
                    (x * 0.94, top + 8, z * 0.94), links=14, sag=0.16, thickness=0.7)

    # ------------------------------------------------------------- турели
    turret_spots = [
        (170, 60, 24), (-190, 120, 18), (60, -190, 30), (-120, -170, 22),
        (230, -60, 26), (-60, 230, 20),
    ]
    for i, (x, z, top) in enumerate(turret_spots):
        pillar_platform(rng, map_root, x, z, top, radius=13.0, height=52.0)
        mount = M.turret_mount(turret_mounts, (x, top, z), name="TurretMount%d" % (i + 1))
        M.torch(map_root, (x + 9, top, z), height=5.0, scale=0.9)

    # ------------------------------------------------------------- бонусы
    pickup_spots = [
        (0, 34, 40), (60, 44, -30), (-70, 40, 30), (0, 52, -150),
        (120, 60, 90), (-140, 56, -70), (30, 46, 180), (-40, 62, -240),
    ]
    for i, (x, y, z) in enumerate(pickup_spots):
        M.pickup_anchor(pickup_anchors, (x, y, z), name="PickupAnchor%d" % (i + 1))

    # ------------------------------------------------------------- площадки спавна
    pad_spots = [(-34, 1.2, 34), (34, 1.2, 34), (0, 1.2, 56)]
    for i, (x, y, z) in enumerate(pad_spots):
        M.spawn_pad(spawn_pads, (x, y, z), name="DroneSpawn%d" % (i + 1))

    # ------------------------------------------------------------- таблички
    sign_defs = [
        ((0, 8, 62), "ЛАВОВЫЙ КАНЬОН\nДРОНЫ-ПЕРЕХВАТЧИКИ", (0, 0, 0)),
        ((-58, 6, -40), "ОСТОРОЖНО:\nЛАВА!", (0, 0, 0)),
        ((58, 6, -40), "VOLCANO\nOBBY", (0, 0, 0)),
        ((0, 20, -118), "К ЗАМКУ", (0, 0, 0)),
        ((-120, 12, 120), "ВОЛНЫ\nБЕСПИЛОТНИКОВ", (0, 0, 0)),
        ((130, 12, 90), "НЕ ПАДАЙ", (0, 0, 0)),
    ]
    for i, (pos, text, _) in enumerate(sign_defs):
        yaw = face_yaw(-pos[0], -pos[2]) if (pos[0] or pos[2]) else 0.0
        board = M.surface_sign("Sign%d" % (i + 1), (26, 11, 1.6),
                              (pos[0], pos[1], pos[2]), (0, yaw, 0), text,
                              font="Cartoon", canvas=(520, 260))
        # столбы
        for s in (-1, 1):
            off = Vec3(math.cos(math.radians(yaw + 90)) * s * 10, 0,
                       math.sin(math.radians(yaw + 90)) * s * 10)
            board.add(M.part("SignPost", (1.6, 10, 1.6),
                            (pos[0] + off.x, pos[1] - 9.5, pos[2] + off.z),
                            rot=(0, yaw, 0), color=M.WOOD, material="Wood",
                            cancollide=False))
        signs.add(board)

    # ------------------------------------------------------------- маяки по краю
    for i, ang in enumerate((10, 100, 190, 280)):
        dist = 400
        x = math.cos(math.radians(ang)) * dist
        z = math.sin(math.radians(ang)) * dist
        pillar_platform(rng, map_root, x, z, 34, radius=10.0, height=60.0)
        M.beacon_pillar(map_root, (x, 34, z), name="BeaconPillar%d" % (i + 1))

    gameplay.add(spawn_pads, turret_mounts, pickup_anchors, signs)
    return map_root, gameplay
