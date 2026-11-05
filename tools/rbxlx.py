"""
rbxlx.py -- minimal, dependency-free writer for Roblox XML place files (.rbxlx).

Instances are described with the small `Inst` class below.  Property names are
canonical Roblox API names (e.g. "Size", "Color", "Material"); the writer looks
up the *serialized* name and data type in tools/reflection.json (extracted from
the rbx-dom reflection database) and emits the exact XML dialect that Roblox
Studio itself understands.

Only the subset of types used by this project is implemented, which keeps the
output predictable and avoids silently emitting invalid data.
"""

import base64
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "reflection.json"), "r", encoding="utf-8") as fh:
    _REFL = json.load(fh)

CLASSES = _REFL["classes"]
ENUMS = _REFL["enums"]


# --------------------------------------------------------------------------- #
# typed value wrappers
# --------------------------------------------------------------------------- #
class Vec2:
    __slots__ = ("x", "y")

    def __init__(self, x=0.0, y=0.0):
        self.x, self.y = float(x), float(y)

    def __repr__(self):
        return f"Vec2({self.x:g}, {self.y:g})"


class Vec3:
    __slots__ = ("x", "y", "z")

    def __init__(self, x=0.0, y=0.0, z=0.0):
        self.x, self.y, self.z = float(x), float(y), float(z)

    def __add__(self, o):
        return Vec3(self.x + o.x, self.y + o.y, self.z + o.z)

    def __sub__(self, o):
        return Vec3(self.x - o.x, self.y - o.y, self.z - o.z)

    def __mul__(self, s):
        return Vec3(self.x * s, self.y * s, self.z * s)

    def length(self):
        return math.sqrt(self.x ** 2 + self.y ** 2 + self.z ** 2)

    def as_tuple(self):
        return (self.x, self.y, self.z)

    def __repr__(self):
        return f"Vec3({self.x:.3f}, {self.y:.3f}, {self.z:.3f})"


class C3:
    """Color3 in 0..1 floats or 0..255 ints."""

    __slots__ = ("r", "g", "b")

    def __init__(self, r, g, b, scale255=False):
        if scale255:
            r, g, b = r / 255.0, g / 255.0, b / 255.0
        self.r, self.g, self.b = float(r), float(g), float(b)

    def __repr__(self):
        return f"C3({self.r:.3f}, {self.g:.3f}, {self.b:.3f})"


def rgb(r, g, b):
    return C3(r, g, b, scale255=True)


class CF:
    """CFrame: position + row-major 3x3 rotation matrix."""

    __slots__ = ("pos", "m")

    def __init__(self, pos=None, m=None):
        self.pos = pos if isinstance(pos, Vec3) else Vec3(*(pos or (0, 0, 0)))
        self.m = m if m is not None else ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0))

    def __mul__(self, other):
        """CFrame composition: self followed by `other` in self's local space."""
        if isinstance(other, CF):
            return CF(self * other.pos, _matmul(self.m, other.m))
        if isinstance(other, Vec3):
            return Vec3(*[sum(self.m[i][j] * (other.x, other.y, other.z)[j] for j in range(3))
                          for i in range(3)]) + self.pos
        raise TypeError(other)

    def inverse(self):
        mt = _transpose(self.m)
        neg = Vec3(*[-sum(mt[i][j] * (self.pos.x, self.pos.y, self.pos.z)[j] for j in range(3))
                    for i in range(3)])
        return CF(mt, None).with_pos(neg) if False else CF(neg, mt)

    def with_pos(self, pos):
        return CF(pos, self.m)

    @property
    def x(self):
        return self.pos.x

    @property
    def y(self):
        return self.pos.y

    @property
    def z(self):
        return self.pos.z


def _matmul(a, b):
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))


def _transpose(a):
    return tuple(tuple(a[j][i] for j in range(3)) for i in range(3))


def cf_angles(rx=0.0, ry=0.0, rz=0.0):
    """CFrame.Angles equivalent (degrees), applied as Rx * Ry * Rz."""
    x, y, z = [math.radians(v) for v in (rx, ry, rz)]
    cx, sx = math.cos(x), math.sin(x)
    cy, sy = math.cos(y), math.sin(y)
    cz, sz = math.cos(z), math.sin(z)
    mx = ((1, 0, 0), (0, cx, -sx), (0, sx, cx))
    my = ((cy, 0, sy), (0, 1, 0), (-sy, 0, cy))
    mz = ((cz, -sz, 0), (sz, cz, 0), (0, 0, 1))
    return _matmul(_matmul(mx, my), mz)


def cf(pos, rx=0.0, ry=0.0, rz=0.0):
    return CF(Vec3(*pos) if not isinstance(pos, Vec3) else pos, cf_angles(rx, ry, rz))


def cf_look_at(pos, target, up=(0, 1, 0)):
    """CFrame positioned at `pos` whose LookVector (local -Z) points at target."""
    f = Vec3(*(target - pos)) if isinstance(target, Vec3) else Vec3(*(target[0] - pos.x, target[1] - pos.y, target[2] - pos.z))
    fl = f.length()
    if fl < 1e-6:
        return CF(Vec3(*pos) if not isinstance(pos, Vec3) else pos)
    f = f * (1.0 / fl)
    u = Vec3(*up)
    r = Vec3(f.y * u.z - f.z * u.y, f.z * u.x - f.x * u.z, f.x * u.y - f.y * u.x)
    rl = r.length()
    if rl < 1e-6:
        r, rl = Vec3(1, 0, 0), 1.0
    r = r * (1.0 / rl)
    uu = Vec3(r.y * f.z - r.z * f.y, r.z * f.x - r.x * f.z, r.x * f.y - r.y * f.x)
    m = ((r.x, uu.x, -f.x), (r.y, uu.y, -f.y), (r.z, uu.z, -f.z))
    return CF(Vec3(*pos) if not isinstance(pos, Vec3) else pos, m)


class Content:
    __slots__ = ("uri",)

    def __init__(self, uri=None):
        self.uri = uri


class Ref:
    __slots__ = ("target",)

    def __init__(self, target=None):
        self.target = target


class Bin:
    __slots__ = ("data",)

    def __init__(self, data=b""):
        self.data = data


class NumSeq:
    __slots__ = ("keys",)

    def __init__(self, keys):
        # keys: [(time, value, envelope)]
        self.keys = keys


class ColSeq:
    __slots__ = ("keys",)

    def __init__(self, keys):
        # keys: [(time, C3)]
        self.keys = keys


class NumRange:
    __slots__ = ("lo", "hi")

    def __init__(self, lo, hi=None):
        self.lo = lo
        self.hi = lo if hi is None else hi


class UDim2:
    __slots__ = ("sx", "ox", "sy", "oy")

    def __init__(self, sx=0.0, ox=0, sy=0.0, oy=0):
        self.sx, self.ox, self.sy, self.oy = float(sx), int(ox), float(sy), int(oy)


class UDim:
    __slots__ = ("s", "o")

    def __init__(self, s=0.0, o=0):
        self.s, self.o = float(s), int(o)


# --------------------------------------------------------------------------- #
# instance tree
# --------------------------------------------------------------------------- #
class Inst:
    __slots__ = ("cls", "name", "props", "children", "referent", "parent")

    def __init__(self, cls, name=None, children=None, **props):
        self.cls = cls
        self.name = name
        self.props = dict(props)
        self.children = list(children or [])
        self.referent = None
        self.parent = None
        for c in self.children:
            c.parent = self

    # -- tree helpers ------------------------------------------------------- #
    def add(self, *children):
        for c in children:
            if c is None:
                continue
            c.parent = self
            self.children.append(c)
        return self

    def extend(self, children):
        return self.add(*children)

    def find(self, name):
        for c in self.children:
            if c.name == name:
                return c
        return None

    def find_class(self, cls):
        for c in self.children:
            if c.cls == cls:
                return c
        return None

    def walk(self):
        yield self
        for c in self.children:
            yield from c.walk()

    def get(self, key, default=None):
        return self.props.get(key, default)

    def set(self, **props):
        self.props.update(props)
        return self

    def __repr__(self):
        return f"<{self.cls} {self.name!r} children={len(self.children)}>"


# --------------------------------------------------------------------------- #
# formatting helpers
# --------------------------------------------------------------------------- #
def _f(v):
    """Format a float the way Roblox expects (short, no exponent surprises)."""
    v = float(v)
    if v != v or v in (float("inf"), float("-inf")):
        return "0"
    if v == int(v) and abs(v) < 1e15:
        return str(int(v))
    s = f"{v:.7g}"
    if "e" in s or "E" in s:
        s = f"{v:.7f}".rstrip("0").rstrip(".")
    return s


def _esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def _cdata(s):
    # Lua sources can contain "]]"; split it safely.
    return "<![CDATA[" + s.replace("]]>", "]]]]><![CDATA[>") + "]]>"


TAG_FOR_TYPE = {
    "Float32": "float",
    "Float64": "double",
    "Int32": "int",
    "Int64": "int64",
    "Bool": "bool",
    "String": "string",
    "ProtectedString": "ProtectedString",
    "BinaryString": "BinaryString",
    "Content": "Content",
    "ContentId": "Content",
    "Ref": "Ref",
    "Vector2": "Vector2",
    "Vector3": "Vector3",
    "Vector2int16": "Vector2int16",
    "Vector3int16": "Vector3int16",
    "CFrame": "CoordinateFrame",
    "OptionalCoordinateFrame": "OptionalCoordinateFrame",
    "Color3": "Color3",
    "Color3uint8": "Color3uint8",
    "BrickColor": "BrickColor",
    "NumberSequence": "NumberSequence",
    "ColorSequence": "ColorSequence",
    "NumberRange": "NumberRange",
    "Rect2D": "Rect2D",
    "PhysicalProperties": "PhysicalProperties",
    "SharedString": "SharedString",
    "Faces": "Faces",
    "Axes": "Axes",
    "Ray": "Ray",
    "UDim": "UDim",
    "UDim2": "UDim2",
    "Tags": "Tags",
    "Attributes": "Attributes",
    "SecurityCapabilities": "SecurityCapabilities",
    "UniqueId": "UniqueId",
    "Font": "Font",
}


def _props_for_class(cls):
    if cls not in CLASSES:
        raise KeyError(f"class {cls!r} missing from reflection.json")
    return CLASSES[cls]


def _resolve(cls, canonical):
    table = _props_for_class(cls)
    if canonical not in table:
        raise KeyError(f"{cls}.{canonical} missing from reflection.json")
    return table[canonical]  # (serialized, datatype)


def _emit_value_xml(cls, canonical, value, out_indent):
    serialized, dtype = _resolve(cls, canonical)
    if isinstance(dtype, str) and dtype.startswith("Enum:"):
        tag = "token"
    else:
        tag = TAG_FOR_TYPE.get(dtype)
        if tag is None:
            raise KeyError(f"{cls}.{canonical}: unsupported datatype {dtype}")

    # Part.Color and friends serialise through Color3uint8
    if serialized == "Color3uint8":
        tag = "Color3uint8"
    pad = " " * out_indent

    def simple(text):
        return f'{pad}<{tag} name="{serialized}">{text}</{tag}>'

    def subtags(pairs):
        inner = "".join(f"{pad}  <{t}>{_f(v) if isinstance(v, (int, float)) else v}</{t}>" for t, v in pairs)
        return f'{pad}<{tag} name="{serialized}">\n{inner}\n{pad}</{tag}>'

    if tag in ("float", "double", "int", "int64"):
        return simple(_f(value) if isinstance(value, float) else str(int(value)))
    if tag == "bool":
        return simple("true" if value else "false")
    if tag == "token":
        return simple(str(int(value)))
    if tag == "string":
        return simple(_esc(str(value)))
    if tag == "ProtectedString":
        return simple(_cdata(str(value)))
    if tag == "BinaryString":
        raw = value.data if isinstance(value, Bin) else (value or b"")
        return simple(_cdata(base64.b64encode(raw).decode("ascii")) if raw else "")
    if tag == "Content":
        uri = None
        if isinstance(value, Content):
            uri = value.uri
        elif isinstance(value, str):
            uri = value
        if uri:
            return f'{pad}<Content name="{serialized}"><uri>{_esc(uri)}</uri></Content>'
        return f'{pad}<Content name="{serialized}"><null></null></Content>'
    if tag == "Ref":
        tgt = value.target if isinstance(value, Ref) else value
        if tgt is None:
            return f'{pad}<Ref name="{serialized}">null</Ref>'
        return f'{pad}<Ref name="{serialized}">RBX{tgt.referent}</Ref>'
    if tag == "Vector3":
        v = value if isinstance(value, Vec3) else Vec3(*value)
        return subtags([("X", v.x), ("Y", v.y), ("Z", v.z)])
    if tag == "Vector2":
        v = value if isinstance(value, Vec2) else Vec2(*value)
        return subtags([("X", v.x), ("Y", v.y)])
    if tag == "CoordinateFrame":
        c = value if isinstance(value, CF) else CF(value)
        names = ["X", "Y", "Z", "R00", "R01", "R02", "R10", "R11", "R12", "R20", "R21", "R22"]
        vals = [c.pos.x, c.pos.y, c.pos.z] + [c.m[i][j] for i in range(3) for j in range(3)]
        return subtags(list(zip(names, vals)))
    if tag == "Color3":
        c = value if isinstance(value, C3) else C3(*value)
        return subtags([("R", c.r), ("G", c.g), ("B", c.b)])
    if tag == "Color3uint8":
        c = value if isinstance(value, C3) else C3(*value)
        r = max(0, min(255, int(round(c.r * 255))))
        g = max(0, min(255, int(round(c.g * 255))))
        b = max(0, min(255, int(round(c.b * 255))))
        return simple(str(b + (g << 8) + (r << 16)))
    if tag == "NumberRange":
        nr = value if isinstance(value, NumRange) else NumRange(value)
        return simple(f"{_f(nr.lo)} {_f(nr.hi)} ")
    if tag == "NumberSequence":
        ns = value if isinstance(value, NumSeq) else NumSeq(value)
        body = "".join(f"{_f(t)} {_f(v)} {_f(e)} " for t, v, e in ns.keys)
        return simple(body)
    if tag == "ColorSequence":
        cs = value if isinstance(value, ColSeq) else ColSeq(value)
        body = "".join(f"{_f(t)} {_f(c.r)} {_f(c.g)} {_f(c.b)} 0 " for t, c in cs.keys)
        return simple(body)
    if tag == "UDim2":
        u = value if isinstance(value, UDim2) else UDim2(*value)
        return (f'{pad}<UDim2 name="{serialized}">\n'
                f'{pad}  <XS>{_f(u.sx)}</XS>\n{pad}  <XO>{u.ox}</XO>\n'
                f'{pad}  <YS>{_f(u.sy)}</YS>\n{pad}  <YO>{u.oy}</YO>\n'
                f'{pad}</UDim2>')
    if tag == "UDim":
        u = value if isinstance(value, UDim) else UDim(value)
        return (f'{pad}<UDim name="{serialized}">\n'
                f'{pad}  <S>{_f(u.s)}</S>\n{pad}  <O>{u.o}</O>\n{pad}</UDim>')
    if tag == "Faces":
        return simple(str(int(value)))
    raise KeyError(f"{cls}.{canonical}: cannot emit tag {tag}")


# --------------------------------------------------------------------------- #
# serialization
# --------------------------------------------------------------------------- #
def _assign_referents(node, counter, seen=None):
    if seen is None:
        seen = set()
    if id(node) in seen:
        raise ValueError(f"{node.cls} {node.name!r}: объект добавлен в дерево дважды")
    seen.add(id(node))
    node.referent = counter[0]
    counter[0] += 1
    for c in node.children:
        _assign_referents(c, counter, seen)


def _write_inst(node, out, depth):
    pad = " " * (depth * 2)
    out.append(f'{pad}<Item class="{node.cls}" referent="RBX{node.referent}">')
    out.append(f"{pad}  <Properties>")
    if node.name is not None:
        out.append(f'{pad}    <string name="Name">{_esc(node.name)}</string>')
    for key in node.props:
        value = node.props[key]
        if value is None:
            continue
        out.append(_emit_value_xml(node.cls, key, value, (depth * 2) + 4))
    out.append(f"{pad}  </Properties>")
    for c in node.children:
        _write_inst(c, out, depth + 1)
    out.append(f"{pad}</Item>")


def save(root_children, path, extra_meta=None):
    """Write a full .rbxlx place file. `root_children` are the top-level services."""
    pseudo = Inst("DataModel", "DataModel", children=list(root_children))
    _assign_referents(pseudo, [0])
    out = ['<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
           'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
           'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">']
    out.append("  <Meta name=\"ExplicitAutoJoints\">true</Meta>")
    for c in pseudo.children:
        _write_inst(c, out, 1)
    out.append("</roblox>")
    text = "\n".join(out) + "\n"
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return len(text)


def save_model(root, path):
    """Write an .rbxmx model file (no DataModel wrapper)."""
    _assign_referents(root, [0])
    out = ['<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
           'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
           'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">']
    _write_inst(root, out, 1)
    out.append("</roblox>")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")


# --------------------------------------------------------------------------- #
# convenience constructors
# --------------------------------------------------------------------------- #
MATERIAL = ENUMS["Material"]
SHAPE = ENUMS["PartType"]
SURFACE = ENUMS["SurfaceType"]


def part(name, size, pos, rot=None, color=(70, 66, 68), material="Slate",
         transparency=0.0, cancollide=True, anchored=True, shape="Block",
         reflectance=0.0, castshadow=True, massless=False, canquery=True,
         top=None, bottom=None, cls=None):
    """Create a Part (or WedgePart) instance."""
    if rot is None:
        rot = (0.0, 0.0, 0.0)
    if isinstance(rot, CF):
        cframe = rot
        if isinstance(pos, (tuple, list)):
            cframe = rot.with_pos(Vec3(*pos))
    else:
        cframe = cf(pos, *rot)
    if isinstance(pos, Vec3) and not isinstance(rot, CF):
        cframe = CF(pos, cf_angles(*rot))
    cls = cls or ("WedgePart" if shape == "WedgePart" else "Part")
    inst = Inst(
        cls,
        name,
        Size=Vec3(*size),
        CFrame=cframe,
        Color=color if isinstance(color, C3) else rgb(*color),
        Material=MATERIAL[material],
        Transparency=float(transparency),
        Anchored=bool(anchored),
        CanCollide=bool(cancollide),
        CanQuery=bool(canquery),
        CastShadow=bool(castshadow),
        Massless=bool(massless),
        Reflectance=float(reflectance),
        TopSurface=SURFACE[top or "Smooth"],
        BottomSurface=SURFACE[bottom or "Smooth"],
    )
    if cls == "Part":
        inst.props["Shape"] = SHAPE[shape if shape in SHAPE else "Block"]
    return inst


def wedge(name, size, pos, rot=None, **kw):
    """A WedgePart (sloped block)."""
    if isinstance(rot, CF):
        cframe = rot.with_pos(Vec3(*pos)) if isinstance(pos, (tuple, list)) else rot
    else:
        cframe = cf(pos, *(rot or (0.0, 0.0, 0.0)))
    kw.setdefault("color", (70, 66, 68))
    kw.setdefault("material", "Slate")
    kw.setdefault("cancollide", True)
    kw.setdefault("anchored", True)
    return Inst(
        "WedgePart",
        name,
        Size=Vec3(*size),
        CFrame=cframe,
        Color=kw["color"] if isinstance(kw["color"], C3) else rgb(*kw["color"]),
        Material=MATERIAL[kw.get("material", "Slate")],
        Transparency=float(kw.get("transparency", 0.0)),
        Anchored=bool(kw.get("anchored", True)),
        CanCollide=bool(kw.get("cancollide", True)),
        CanQuery=bool(kw.get("canquery", True)),
        CastShadow=bool(kw.get("castshadow", True)),
        Massless=bool(kw.get("massless", False)),
        Reflectance=float(kw.get("reflectance", 0.0)),
    )


def cylinder(name, size, pos, rot=None, **kw):
    kw["shape"] = "Cylinder"
    return part(name, size, pos, rot, **kw)


def ball(name, size, pos, rot=None, **kw):
    kw["shape"] = "Ball"
    return part(name, size, pos, rot, **kw)


def point_light(parent_opts, color=(255, 140, 40), brightness=2.0, rng=40.0, shadows=False, name="Light"):
    return Inst(
        "PointLight",
        name,
        Color=color if isinstance(color, C3) else rgb(*color),
        Brightness=float(brightness),
        Range=float(rng),
        Shadows=bool(shadows),
        Enabled=True,
    )


def particles(name, rate=20.0, lifetime=(2.0, 4.0), speed=(4.0, 12.0), size=(0.4, 1.6),
              color_keys=None, transparency_keys=None, accel=(0, 10, 0), drag=0.0,
              spread=(180.0, 180.0), light_emission=0.6, brightness=1.0,
              emission_direction="Top", rotation=None, rot_speed=None, zoffset=0.0,
              squash=None):
    color_keys = color_keys or [(0.0, rgb(255, 190, 90)), (1.0, rgb(120, 20, 0))]
    transparency_keys = transparency_keys or [(0.0, 0.1), (0.6, 0.45), (1.0, 1.0)]
    return Inst(
        "ParticleEmitter",
        name,
        Rate=float(rate),
        Lifetime=NumRange(*lifetime),
        Speed=NumRange(*speed),
        Size=NumSeq([(t, v, 0.0) for t, v in size] if isinstance(size, list) else [(0, size[0], 0), (1, size[1], 0)]),
        Color=ColSeq([(t, c) for t, c in color_keys]),
        Transparency=NumSeq([(t, v, 0.0) for t, v in transparency_keys]),
        Acceleration=Vec3(*accel),
        Drag=float(drag),
        SpreadAngle=Vec2(*spread),
        LightEmission=float(light_emission),
        Brightness=float(brightness),
        EmissionDirection=ENUMS["NormalId"][emission_direction],
        Enabled=True,
        LockedToPart=False,
        ZOffset=float(zoffset),
        Squash=NumSeq(squash or [(0, 0.0, 0), (1, 0.3, 0)]),
    )


def surface_sign(name, size, pos, rot, text, text_color=(255, 236, 210), bg=(38, 26, 20),
                 face="Front", font="Cartoon", scaled=True, canvas=(400, 200)):
    """A wooden sign with a SurfaceGui label."""
    board = part(name, size, pos, rot, color=bg, material="WoodPlanks", cancollide=True)
    gui = Inst("SurfaceGui", "Sign", Face=ENUMS["NormalId"][face], SizingMode=0,
               PixelsPerStud=50, LightInfluence=0.35, AlwaysOnTop=True, Enabled=True)
    label = Inst("TextLabel", "Text", Size=UDim2(1, 0, 1, 0), Position=UDim2(0, 0, 0, 0),
                 BackgroundTransparency=1.0, Text=text,
                 TextColor3=text_color if isinstance(text_color, C3) else rgb(*text_color),
                 TextScaled=bool(scaled), Font=ENUMS["Font"][font], TextWrapped=True,
                 TextStrokeTransparency=0.45, TextXAlignment=ENUMS["TextXAlignment"]["Center"],
                 TextYAlignment=ENUMS["TextYAlignment"]["Center"])
    gui.add(label)
    board.add(gui)
    return board
