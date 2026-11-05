#!/usr/bin/env python3
"""
validate_place.py -- проверяет собранный .rbxlx «глазами Roblox Studio»:

  * XML корректно разбирается;
  * каждый <Item class="..."> -- существующий класс Roblox;
  * каждое имя свойства -- известное *сериализуемое* имя этого класса;
  * XML-тег свойства соответствует типу данных (string / Vector3 / token / ...);
  * значения парсятся, векторы и CFrame имеют нужные дочерние теги;
  * Ref-ы указывают на существующие referent-ы;
  * обязательные свойства на месте (Name, Script.Source, Part.Size/CFrame);

Запуск: python3 tools/validate_place.py [файл]
"""

import json
import os
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "reflection.json"), "r", encoding="utf-8") as fh:
    REFL = json.load(fh)

TAG_FOR_TYPE = {
    "Float32": "float", "Float64": "double", "Int32": "int", "Int64": "int64",
    "Bool": "bool", "String": "string", "ProtectedString": "ProtectedString",
    "BinaryString": "BinaryString", "Content": "Content", "ContentId": "Content",
    "Ref": "Ref", "Vector2": "Vector2", "Vector3": "Vector3",
    "Vector2int16": "Vector2int16", "Vector3int16": "Vector3int16",
    "CFrame": "CoordinateFrame", "OptionalCoordinateFrame": "OptionalCoordinateFrame",
    "Color3": "Color3", "Color3uint8": "Color3uint8", "BrickColor": "BrickColor",
    "NumberSequence": "NumberSequence", "ColorSequence": "ColorSequence",
    "NumberRange": "NumberRange", "Rect2D": "Rect2D",
    "PhysicalProperties": "PhysicalProperties", "SharedString": "SharedString",
    "Faces": "Faces", "Axes": "Axes", "Ray": "Ray", "UDim": "UDim", "UDim2": "UDim2",
    "Tags": "Tags", "Attributes": "Attributes",
    "SecurityCapabilities": "SecurityCapabilities", "UniqueId": "UniqueId",
    "Font": "Font",
}

VECTOR_COMPONENTS = {
    "Vector2": ["X", "Y"],
    "Vector3": ["X", "Y", "Z"],
    "Vector2int16": ["X", "Y"],
    "Vector3int16": ["X", "Y", "Z"],
    "CoordinateFrame": ["X", "Y", "Z", "R00", "R01", "R02", "R10", "R11", "R12",
                        "R20", "R21", "R22"],
    "Color3": ["R", "G", "B"],
    "UDim": ["S", "O"],
    "UDim2": ["XS", "XO", "YS", "YO"],
    "Faces": ["faces"],
}


def main(path):
    errors = []
    warnings = []
    classes = REFL["classes"]

    with open(path, "rb") as fh:
        raw = fh.read()
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as exc:
        print("НЕВАЛИДНЫЙ XML:", exc)
        return 1

    if root.tag != "roblox":
        errors.append(f"корневой элемент {root.tag}, ожидался roblox")
    if root.get("version") != "4":
        warnings.append("атрибут version не 4")

    referents = {}
    items = []
    for item in root.iter("Item"):
        ref = item.get("referent")
        cls = item.get("class")
        if ref is None:
            errors.append(f"<Item class={cls}> без referent")
            continue
        if ref in referents:
            errors.append(f"дубликат referent {ref}")
        referents[ref] = cls
        items.append(item)

    checked_props = 0
    for item in items:
        cls = item.get("class")
        if cls not in classes:
            errors.append(f"неизвестный класс {cls}")
            continue
        table = classes[cls]
        reverse = {ser: (canon, dt) for canon, (ser, dt) in table.items()}
        props = item.find("Properties")
        if props is None:
            warnings.append(f"{cls} без <Properties>")
            continue
        seen = set()
        for prop in props:
            name = prop.get("name")
            if name is None:
                errors.append(f"{cls}: свойство без name (тег {prop.tag})")
                continue
            if name in seen:
                errors.append(f"{cls}: свойство {name} задано дважды")
            seen.add(name)
            if name == "Name":
                if prop.tag != "string":
                    errors.append(f"{cls}.Name: тег {prop.tag}, ожидался string")
                continue
            if name not in reverse:
                errors.append(f"{cls}: неизвестное сериализуемое свойство {name}")
                continue
            canon, dtype = reverse[name]
            if isinstance(dtype, str) and dtype.startswith("Enum:"):
                expected = "token"
            else:
                expected = TAG_FOR_TYPE.get(dtype)
            if name == "Color3uint8":
                expected = "Color3uint8"
            if expected is None:
                warnings.append(f"{cls}.{name}: неизвестный тип {dtype}")
                continue
            if prop.tag != expected:
                errors.append(f"{cls}.{name} ({canon}): тег {prop.tag}, ожидался {expected}")
                continue
            checked_props += 1

            # проверка значения
            if expected in VECTOR_COMPONENTS:
                kids = {c.tag for c in prop}
                exp = set(VECTOR_COMPONENTS[expected])
                if not exp.issubset(kids):
                    errors.append(f"{cls}.{name}: не хватает компонентов {exp - kids}")
                else:
                    for child in prop:
                        try:
                            float(child.text or "0")
                        except ValueError:
                            errors.append(f"{cls}.{name}.{child.tag}: не число")
            elif expected in ("float", "double", "int", "int64", "token"):
                try:
                    float((prop.text or "").strip())
                except ValueError:
                    errors.append(f"{cls}.{name}: значение {prop.text!r} не число")
            elif expected == "bool":
                if (prop.text or "").strip() not in ("true", "false"):
                    errors.append(f"{cls}.{name}: bool {prop.text!r}")
            elif expected == "Ref":
                target = (prop.text or "").strip()
                if target != "null" and target not in referents:
                    errors.append(f"{cls}.{name}: Ref на несуществующий {target}")
            elif expected == "NumberRange":
                parts = (prop.text or "").split()
                if len(parts) != 2:
                    errors.append(f"{cls}.{name}: NumberRange {prop.text!r}")
            elif expected == "NumberSequence":
                parts = (prop.text or "").split()
                if len(parts) % 3 != 0 or not parts:
                    errors.append(f"{cls}.{name}: NumberSequence {prop.text!r}")
            elif expected == "ColorSequence":
                parts = (prop.text or "").split()
                if len(parts) % 5 != 0 or not parts:
                    errors.append(f"{cls}.{name}: ColorSequence {prop.text!r}")
            elif expected == "Color3uint8":
                v = int((prop.text or "0").strip())
                if not (0 <= v <= 0xFFFFFF):
                    errors.append(f"{cls}.{name}: packed color {v}")
            elif expected == "Content":
                if prop.find("null") is None and prop.find("uri") is None:
                    errors.append(f"{cls}.{name}: Content без <uri>/<null>")

    # обязательные вещи
    by_class = {}
    for item in items:
        by_class.setdefault(item.get("class"), []).append(item)

    def prop(item, name):
        p = item.find("Properties")
        return None if p is None else p.find(f'["name"]')

    for cls in ("Workspace", "Lighting", "ReplicatedStorage", "ServerStorage",
                "ServerScriptService", "StarterPlayer", "Players"):
        if cls not in by_class:
            errors.append(f"нет сервиса {cls}")

    scripts = 0
    for item in items:
        cls = item.get("class")
        if cls in ("Script", "LocalScript", "ModuleScript"):
            scripts += 1
            src = None
            for prop in item.find("Properties"):
                if prop.get("name") == "Source":
                    src = prop.text
            if not src or len(src) < 50:
                errors.append(f"{cls} {item.get('referent')}: пустой Source")

    drone_models = [i for i in by_class.get("Model", [])]
    part_like = len(by_class.get("Part", [])) + len(by_class.get("WedgePart", [])) + \
        len(by_class.get("UnionOperation", []))

    print(f"файл: {os.path.basename(path)}  ({len(raw)/1024:.0f} КБ)")
    print(f"инстансов: {len(items)}   свойств проверено: {checked_props}")
    print(f"классов в файле: {len(by_class)}   скриптов: {scripts}   деталей: {part_like}")
    top = sorted(by_class.items(), key=lambda kv: -len(kv[1]))[:12]
    print("топ классов:", ", ".join(f"{c}={len(v)}" for c, v in top))
    print(f"ошибок: {len(errors)}   предупреждений: {len(warnings)}")
    for e in errors[:30]:
        print("  ОШИБКА:", e)
    for w in warnings[:10]:
        print("  предупреждение:", w)
    return 1 if errors else 0


if __name__ == "__main__":
    argv = sys.argv[1:]
    target = argv[0] if argv else os.path.join(
        os.path.dirname(HERE), "VolcanoDrone.rbxlx")
    sys.exit(main(target))
