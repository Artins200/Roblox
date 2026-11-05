#!/usr/bin/env python3
"""
check_enums.py -- сверяет Enum.X.Y и Instance.new("Class") в Luau-скриптах
с официальной базой Roblox API (rbx-dom database.json).

Запуск: python3 tools/check_enums.py [путь к database.json]
"""

import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DB = "/tmp/rbxdom/rbx-dom-master/rbx_dom_lua/src/database.json"

ENUM_RE = re.compile(r"\bEnum\.([A-Za-z_0-9]+)\.([A-Za-z_0-9]+)")
CLASS_RE = re.compile(r"\bInstance\.new\(\s*\"([A-Za-z_0-9]+)\"\s*[,)]")
WARN_PROP_RE = re.compile(r"\b(?:Enum\.)?([A-Z][A-Za-z0-9]*)\.(\w+)\b")


def main(db_path):
    with open(db_path, "r", encoding="utf-8") as fh:
        db = json.load(fh)
    enums = {name: set(info["items"].keys()) for name, info in db["Enums"].items()}
    classes = set(db["Classes"].keys())

    files = sorted(glob.glob(os.path.join(ROOT, "src", "**", "*.luau"), recursive=True))
    bad = 0
    enum_uses = 0
    class_uses = 0
    for path in files:
        rel = os.path.relpath(path, ROOT)
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
        problems = []

        for enum, item in ENUM_RE.findall(text):
            enum_uses += 1
            if enum not in enums:
                problems.append(f"Enum.{enum} -- нет такого перечисления")
            elif item not in enums[enum]:
                problems.append(f"Enum.{enum}.{item} -- нет такого значения")

        for cls in CLASS_RE.findall(text):
            class_uses += 1
            if cls not in classes:
                problems.append(f"Instance.new(\"{cls}\") -- нет такого класса")

        print(f"{rel:60s} Enum-обращений: {len(ENUM_RE.findall(text)):4d}   "
              f"{(len(problems) or 'OK') if problems else 'OK'}")
        for p in sorted(set(problems)):
            print("     ", p)
        bad += len(problems)

    print()
    print(f"проверено Enum-обращений: {enum_uses}, Instance.new: {class_uses}, "
          f"проблем: {bad}")
    return 1 if bad else 0


if __name__ == "__main__":
    db = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DB
    if not os.path.exists(db):
        print("нет базы:", db)
        sys.exit(2)
    sys.exit(main(db))
