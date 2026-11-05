"""
drone_import.py -- превращает модели дронов из исходного hh.rbxl в узлы rbxlx,
разворачивая их в «правильную» полётную ориентацию.

Авторские модели в файле выставлены с произвольным ручным поворотом.
По геометрии (пушка слева/справа, камера спереди, бомба под брюхом) локальные оси
модели такие:

    +X_local -- вниз            (бомба "Bomb :3" висит на +X)
    +Y_local -- влево/вправо    (два минигана на +Y и -Y)
    +Z_local -- вперёд          (камера на +Z, красный маяк на носу)

Поэтому поворачиваем модель так, чтобы в игре она стояла «вверх = +Y» и
«вперёд = -Z» (стандарт Roblox: LookVector = -Z), и центрируем по центру масс.
"""

import rbxl_reader as reader
from rbxlx import C3, CF, Content, Inst, Vec3, rgb

# T: локальные оси модели -> оси мира
#   T(+X_local) = (0,-1,0)  (низ модели уходит вниз мира)
#   T(+Z_local) = (0,0,-1)  (нос смотрит вперёд = -Z)
#   T(+Y_local) = (-1,0,0)
T_ROWS = ((0.0, -1.0, 0.0), (-1.0, 0.0, 0.0), (0.0, 0.0, -1.0))


def _mat_mul(a, b):
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))


def _mat_vec(a, v):
    return Vec3(*[sum(a[i][k] * v[k] for k in range(3)) for i in range(3)])


def _transpose(a):
    return tuple(tuple(a[j][i] for j in range(3)) for i in range(3))


def _cf_from(value):
    """('CFrame', pos, rot) -> rbxlx.CF"""
    return CF(Vec3(*value[1]), value[2])


PART_PROPS = [
    "Size", "CFrame", "Color", "Material", "Transparency", "Reflectance", "Anchored",
    "CanCollide", "CastShadow", "Massless", "Locked", "CanQuery", "CanTouch",
    "TopSurface", "BottomSurface", "LeftSurface", "RightSurface", "FrontSurface",
    "BackSurface", "FormFactor",
]
SHAPE_ORDER = ["Ball", "Block", "Cylinder", "Wedge", "CornerWedge"]

UNION_PROPS = [
    "Size", "CFrame", "Color", "Material", "Transparency", "Reflectance", "Anchored",
    "CanCollide", "CastShadow", "Massless", "InitialSize", "UsePartColor",
    "TriangleCount", "SmoothingAngle",
]


def _convert_value(cls, canonical, raw, reverse):
    """Convert a decoded binary value into the rbxlx type for `canonical`."""
    serialized = reverse.get(canonical)
    if serialized is None:
        return None
    if isinstance(raw, tuple):
        kind = raw[0]
        if kind == "Vector3":
            return Vec3(raw[1], raw[2], raw[3])
        if kind == "Vector2":
            return raw  # not used by the drone
        if kind == "CFrame":
            return CF(Vec3(*raw[1]), raw[2])
        if kind == "Color3uint8":
            return rgb(raw[1], raw[2], raw[3])
        if kind == "Color3":
            return C3(raw[1], raw[2], raw[3])
        return None
    if isinstance(raw, bytes):
        return raw.decode("utf-8", "replace")
    return raw


def _reverse_map(cls):
    from rbxlx import CLASSES
    table = CLASSES[cls]
    return {ser: canon for canon, (ser, _dt) in table.items()}


def import_model(src, name=None, extra_offset=None):
    """Convert a parsed drbxl model instance into an rbxlx Inst tree."""
    parts = []

    def collect(node):
        for child in node.children:
            if child.cls in ("Part", "UnionOperation", "WedgePart", "MeshPart"):
                parts.append(child)
            collect(child)

    collect(src)

    handle = None
    for p in parts:
        if p.name == "Handle":
            handle = p
            break
    if handle is None:
        # самая большая деталь
        handle = max(parts, key=lambda p: (p.props.get("size", ("", 1, 1, 1))[1] *
                                           p.props.get("size", ("", 1, 1, 1))[2] *
                                           p.props.get("size", ("", 1, 1, 1))[3]))

    h_cf = _cf_from(handle.props["CFrame"])
    h_inv = h_cf.inverse()
    t_cf = CF(Vec3(0, 0, 0), T_ROWS)

    # 1) поворачиваем все детали в полётную ориентацию
    placed = []
    lo = [1e9] * 3
    hi = [-1e9] * 3
    for p in parts:
        local = h_inv * _cf_from(p.props["CFrame"])
        world = t_cf * local
        placed.append((p, world))
        size = p.props.get("size", ("Vector3", 1, 1, 1))[1:]
        for axis in range(3):
            ext = sum(abs(world.m[axis][k]) * size[k] for k in range(3))
            lo[axis] = min(lo[axis], world.pos.as_tuple()[axis] - ext / 2)
            hi[axis] = max(hi[axis], world.pos.as_tuple()[axis] + ext / 2)

    center = Vec3((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2)

    # 2) смещаем так, чтобы центр был в (0, 0, 0) — удобно для физики/камеры
    offset = Vec3(-center.x, -center.y, -center.z)
    if extra_offset:
        offset = offset + Vec3(*extra_offset)

    out_parts = {}
    for p, world in placed:
        reverse = _reverse_map(p.cls)
        props = {}
        whitelist = UNION_PROPS if p.cls == "UnionOperation" else PART_PROPS
        for canonical in whitelist:
            serialized = reverse.get(canonical)
            if serialized is None or serialized not in p.props:
                continue
            value = _convert_value(p.cls, canonical, p.props[serialized], reverse)
            if value is None:
                continue
            if canonical == "CFrame":
                value = value.with_pos(value.pos + offset)
            props[canonical] = value

        # форма детали
        if p.cls == "Part":
            shape_raw = p.props.get("shape", 1)
            props["Shape"] = shape_raw if isinstance(shape_raw, int) else 1

        props["Anchored"] = True   # в шаблоне детали закреплены; игра их разваривает
        props["Color"] = props.get("Color", rgb(99, 95, 98))
        props["Material"] = props.get("Material", 1056)

        cls = p.cls if p.cls in ("Part", "UnionOperation", "WedgePart") else "Part"
        inst = Inst(cls, p.name, **props)
        out_parts[p.ref] = inst

        # дочерние объекты (SpecialMesh у Handle)
        for child in p.children:
            if child.cls == "SpecialMesh":
                mesh_props = {}
                rev = _reverse_map("SpecialMesh")
                for canonical in ("MeshType", "MeshId", "TextureId", "Scale", "Offset",
                                  "VertexColor"):
                    serialized = rev.get(canonical)
                    if serialized is None or serialized not in child.props:
                        continue
                    raw = child.props[serialized]
                    if canonical in ("MeshId", "TextureId"):
                        uri = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else str(raw)
                        mesh_props[canonical] = Content(uri)
                    else:
                        val = _convert_value("SpecialMesh", canonical, raw, rev)
                        if val is not None:
                            mesh_props[canonical] = val
                inst.add(Inst("SpecialMesh", child.name, **mesh_props))

    # 3) собираем дерево модели (плоско, как в исходнике)
    model = Inst("Model", name or src.name)
    for p, _world in placed:
        model.add(out_parts[p.ref])

    # PrimaryPart = Handle (или самая большая деталь)
    primary = out_parts.get(handle.ref)
    if primary is None and model.children:
        primary = model.children[0]
    if primary is not None:
        from rbxlx import Ref
        model.props["PrimaryPart"] = Ref(primary)

    return model, {"size": (hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]), "center": center}


def load_source(path):
    roots, meta, instances = reader.load(path)
    ws = None
    for r in roots:
        if r.cls == "Workspace":
            ws = r
            break
    models = {}
    if ws:
        for child in ws.children:
            if child.cls == "Model":
                models[child.name] = child
    return models
