#!/usr/bin/env python3
"""
build_place.py -- собирает итоговый файл места VolcanoDrone.rbxlx:

    1) читает исходный hh.rbxl (двоичный) и достаёт модели дронов автора;
    2) разворачивает их в полётную ориентацию и кладёт в ServerStorage;
    3) генерирует арену «Лавовый каньон» (tools/arena.py);
    4) зашивает скрипты из src/ (сервер, клиент, HUD, конфиг);
    5) настраивает освещение, атмосферу и небо;
    6) пишет XML-плейс, который открывается в Roblox Studio.

Запуск:  python3 tools/build_place.py
"""

import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rbxlx as X
from rbxlx import (CF, C3, Content, Inst, NumRange, UDim2, Vec2, Vec3, cf, cf_angles,
                   cylinder, rgb, ENUMS)

import arena
import drone_import
import volcano_map as M

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
OUT = os.path.join(ROOT, "VolcanoDrone.rbxlx")
SOURCE_PLACE = os.path.join(ROOT, "hh.rbxl")


# --------------------------------------------------------------------------- #
# помощники
# --------------------------------------------------------------------------- #
def read_src(*parts):
    with open(os.path.join(SRC, *parts), "r", encoding="utf-8") as fh:
        return fh.read()


def script(cls, name, path):
    return Inst(cls, name, Source=read_src(*path))


# --------------------------------------------------------------------------- #
# освещение / атмосфера
# --------------------------------------------------------------------------- #
def build_lighting():
    lighting = Inst(
        "Lighting", "Lighting",
        Ambient=rgb(76, 46, 38),
        OutdoorAmbient=rgb(104, 60, 44),
        Brightness=2.2,
        ClockTime=8.4,
        GeographicLatitude=0.0,
        ExposureCompensation=0.16,
        EnvironmentDiffuseScale=0.5,
        EnvironmentSpecularScale=0.6,
        GlobalShadows=True,
        ShadowSoftness=0.38,
        Technology=ENUMS["Technology"]["ShadowMap"],
        FogColor=rgb(158, 70, 38),
        FogStart=180.0,
        FogEnd=2100.0,
        ColorShift_Top=rgb(255, 148, 70),
        ColorShift_Bottom=rgb(64, 14, 0),
    )

    sky = Inst(
        "Sky", "Sky",
        CelestialBodiesShown=True,
        StarCount=600,
        SunAngularSize=13.0,
        MoonAngularSize=0.0,
        SkyboxBk=Content("rbxassetid://6444884337"),
        SkyboxDn=Content("rbxassetid://6444884785"),
        SkyboxFt=Content("rbxassetid://6444884337"),
        SkyboxLf=Content("rbxassetid://6444884337"),
        SkyboxRt=Content("rbxassetid://6444884337"),
        SkyboxUp=Content("rbxassetid://6412503613"),
        SunTextureId=Content("rbxassetid://6196665106"),
        MoonTextureId=Content("rbxassetid://6444320592"),
        SkyboxOrientation=Vec3(0, 0, 0),
    )

    atmosphere = Inst(
        "Atmosphere", "Atmosphere",
        Density=0.44,
        Offset=0.12,
        Color=rgb(255, 152, 104),
        Decay=rgb(118, 54, 38),
        Glare=0.45,
        Haze=1.7,
    )

    bloom = Inst("BloomEffect", "Bloom", Intensity=1.35, Size=28.0, Threshold=1.05,
                 Enabled=True)
    sunrays = Inst("SunRaysEffect", "SunRays", Intensity=0.12, Spread=0.72, Enabled=True)
    dof = Inst("DepthOfFieldEffect", "DepthOfField", FarIntensity=0.08,
               FocusDistance=90.0, InFocusRadius=260.0, NearIntensity=0.0, Enabled=False)
    cce = Inst("ColorCorrectionEffect", "ColorCorrection", Brightness=0.03,
               Contrast=0.14, Saturation=0.2, TintColor=rgb(255, 224, 200),
               Enabled=True)

    lighting.add(sky, atmosphere, bloom, sunrays, dof, cce)
    return lighting


# --------------------------------------------------------------------------- #
# сборка
# --------------------------------------------------------------------------- #
def build():
    if not os.path.exists(SOURCE_PLACE):
        raise SystemExit("Не найден hh.rbxl рядом с tools/")

    print("[1/6] читаю исходный hh.rbxl ...")
    models = drone_import.load_source(SOURCE_PLACE)
    print("      модели в Workspace:", ", ".join(models.keys()) or "(нет)")

    # ---------------------------------------------------------------- дроны
    print("[2/6] импортирую модели дронов ...")
    server_storage = Inst("ServerStorage", "ServerStorage")
    drone_names = []
    for name in ("Беспилотник", "скинБеспилотник"):
        if name not in models:
            print("      ! модель", name, "не найдена, пропускаю")
            continue
        model, info = drone_import.import_model(models[name], name=name)
        server_storage.add(model)
        drone_names.append(name)
        print("      %-18s деталей: %3d  габариты: %.1f x %.1f x %.1f" % (
            name, len(model.children), *info["size"]))

    if not drone_names:
        raise SystemExit("В файле не нашлось моделей дронов")

    # ---------------------------------------------------------------- арена
    print("[3/6] строю арену ...")
    map_root, gameplay = arena.build_arena()
    part_count = sum(1 for _ in map_root.walk()) + sum(1 for _ in gameplay.walk())
    print("      объектов в арене:", part_count)

    # ---------------------------------------------------------------- скрипты
    print("[4/6] вшиваю скрипты ...")
    replicated = Inst("ReplicatedStorage", "ReplicatedStorage")
    replicated.add(script("ModuleScript", "DroneConfig",
                          ("ReplicatedStorage", "DroneConfig.luau")))

    server_scripts = Inst("ServerScriptService", "ServerScriptService")
    server_scripts.add(script("Script", "DroneServer",
                              ("ServerScriptService", "DroneServer.server.luau")))

    starter_scripts = Inst("Folder", "StarterPlayerScripts")
    starter_scripts.add(
        script("LocalScript", "DroneClient",
               ("StarterPlayer", "StarterPlayerScripts", "DroneClient.client.luau")))
    starter_scripts.add(
        script("ModuleScript", "DroneUI",
               ("StarterPlayer", "StarterPlayerScripts", "DroneUI.luau")))

    starter_player = Inst("StarterPlayer", "StarterPlayer")
    starter_player.add(starter_scripts, Inst("Folder", "StarterCharacterScripts"))

    # ---------------------------------------------------------------- workspace
    print("[5/6] собираю сервисы ...")
    workspace = Inst(
        "Workspace", "Workspace",
        Gravity=196.2,
        FallenPartsDestroyHeight=-420.0,
        StreamingEnabled=False,
    )
    camera = Inst(
        "Camera", "Camera",
        CFrame=cf((150, 190, 330), -12, 152, 0),
        FieldOfView=74.0,
        CameraType=ENUMS["CameraType"]["Scriptable"],
    )
    workspace.add(camera, Inst("Terrain", "Terrain"), map_root, gameplay)

    players = Inst("Players", "Players", CharacterAutoLoads=False)
    lighting = build_lighting()
    starter_gui = Inst("StarterGui", "StarterGui")
    roots = [workspace, lighting, replicated, server_storage, server_scripts,
             starter_player, starter_gui, players]

    # ---------------------------------------------------------------- запись
    print("[6/6] записываю", os.path.basename(OUT), "...")
    size = X.save(roots, OUT)
    total_instances = sum(1 for r in roots for _ in r.walk())
    print("      готово: %s (%.1f КБ, %d объектов)" % (
        os.path.basename(OUT), size / 1024.0, total_instances))
    return OUT


if __name__ == "__main__":
    build()
