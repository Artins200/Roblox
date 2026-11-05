"""
rbxl_reader.py -- reader for Roblox *binary* place/model files (.rbxl / .rbxm).

Implements the chunk framing used by Roblox Studio (header, META, SSTR, INST,
PROP, PRNT, END with zstd-compressed payloads) and the zig-zag / column-major
("interleaved") scalar encoding used inside the chunks.

Property values are returned keyed by their *serialized* name (the names the
binary format actually stores, e.g. "size", "shape", "Color3uint8").
"""

import struct

import zstandard as zstd

MAGIC = b"<roblox!"
SIGNATURE = b"\x89\xff\x0d\x0a\x1a\x0a"


# --------------------------------------------------------------------------- #
# primitives
# --------------------------------------------------------------------------- #
def _untransform_i32(value):
    value &= 0xFFFFFFFF
    return (value >> 1) ^ (-(value & 1))


class _Reader:
    __slots__ = ("buf", "pos")

    def __init__(self, buf, pos=0):
        self.buf = buf
        self.pos = pos

    def u8(self):
        v = self.buf[self.pos]
        self.pos += 1
        return v

    def u16(self):
        v = struct.unpack_from("<H", self.buf, self.pos)[0]
        self.pos += 2
        return v

    def u32(self):
        v = struct.unpack_from("<I", self.buf, self.pos)[0]
        self.pos += 4
        return v

    def i32(self):
        v = struct.unpack_from("<i", self.buf, self.pos)[0]
        self.pos += 4
        return v

    def f32(self):
        v = struct.unpack_from("<f", self.buf, self.pos)[0]
        self.pos += 4
        return v

    def f64(self):
        v = struct.unpack_from("<d", self.buf, self.pos)[0]
        self.pos += 8
        return v

    def i64(self):
        v = struct.unpack_from("<q", self.buf, self.pos)[0]
        self.pos += 8
        return v

    def raw(self, n):
        v = self.buf[self.pos:self.pos + n]
        self.pos += n
        return v

    def string(self):
        n = self.u32()
        return self.raw(n).decode("utf-8", "replace")

    def bytes(self):
        n = self.u32()
        return self.raw(n)


def _f32_array(r, n):
    """Column-major big-endian f32 with the Roblox 1-bit rotate."""
    buf = r.raw(n * 4)
    out = []
    for i in range(n):
        be = struct.unpack(">I", bytes(buf[i::n]))[0]
        rot = ((be >> 1) | (be << 31)) & 0xFFFFFFFF
        out.append(struct.unpack("<f", struct.pack("<I", rot))[0])
    return out


def _i32_array(r, n):
    buf = r.raw(n * 4)
    return [_untransform_i32(struct.unpack(">I", bytes(buf[i::n]))[0]) for i in range(n)]


def _u32_array(r, n):
    buf = r.raw(n * 4)
    return [struct.unpack(">I", bytes(buf[i::n]))[0] for i in range(n)]


def _referents(r, n):
    vals = _i32_array(r, n)
    out, last = [], 0
    for v in vals:
        last += v
        out.append(last)
    return out


BASIC_ROTATIONS = {
    0x02: ((1, 0, 0), (0, 1, 0), (0, 0, 1)),
    0x03: ((1, 0, 0), (0, 0, -1), (0, 1, 0)),
    0x05: ((1, 0, 0), (0, -1, 0), (0, 0, -1)),
    0x06: ((1, 0, 0), (0, 0, 1), (0, -1, 0)),
    0x07: ((0, 1, 0), (1, 0, 0), (0, 0, -1)),
    0x09: ((0, 0, 1), (1, 0, 0), (0, 1, 0)),
    0x0A: ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
    0x0C: ((0, 0, -1), (1, 0, 0), (0, -1, 0)),
    0x0D: ((0, 1, 0), (0, 0, 1), (1, 0, 0)),
    0x0E: ((0, 0, -1), (0, 1, 0), (1, 0, 0)),
    0x10: ((0, -1, 0), (0, 0, -1), (1, 0, 0)),
    0x11: ((0, 0, 1), (0, -1, 0), (1, 0, 0)),
    0x14: ((-1, 0, 0), (0, 1, 0), (0, 0, -1)),
    0x15: ((-1, 0, 0), (0, 0, 1), (0, 1, 0)),
    0x17: ((-1, 0, 0), (0, -1, 0), (0, 0, 1)),
    0x18: ((-1, 0, 0), (0, 0, -1), (0, -1, 0)),
    0x19: ((0, 1, 0), (-1, 0, 0), (0, 0, 1)),
    0x1B: ((0, 0, -1), (-1, 0, 0), (0, 1, 0)),
    0x1C: ((0, -1, 0), (-1, 0, 0), (0, 0, -1)),
    0x1E: ((0, 0, 1), (-1, 0, 0), (0, -1, 0)),
    0x1F: ((0, 1, 0), (0, 0, -1), (-1, 0, 0)),
    0x20: ((0, 0, 1), (0, 1, 0), (-1, 0, 0)),
    0x22: ((0, -1, 0), (0, 0, 1), (-1, 0, 0)),
    0x23: ((0, 0, -1), (0, -1, 0), (-1, 0, 0)),
}


class Instance:
    __slots__ = ("ref", "cls", "name", "props", "children", "parent")

    def __init__(self, ref, cls):
        self.ref = ref
        self.cls = cls
        self.name = cls
        self.props = {}
        self.children = []
        self.parent = None

    def walk(self):
        yield self
        for c in self.children:
            yield from c.walk()

    def __repr__(self):
        return f"<{self.cls} {self.name!r}>"


def _decode_prop(r, tag, n):
    """Return a list of `n` decoded values (or None when unsupported)."""
    if tag == 0x01:
        return [r.bytes() for _ in range(n)]
    if tag == 0x02:
        return [r.u8() != 0 for _ in range(n)]
    if tag == 0x03:
        return _i32_array(r, n)
    if tag == 0x04:
        return _f32_array(r, n)
    if tag == 0x05:
        return [r.f64() for _ in range(n)]
    if tag == 0x06:
        s, o = _f32_array(r, n), _i32_array(r, n)
        return [("UDim", s[i], o[i]) for i in range(n)]
    if tag == 0x07:
        sx, sy = _f32_array(r, n), _f32_array(r, n)
        ox, oy = _i32_array(r, n), _i32_array(r, n)
        return [("UDim2", (sx[i], ox[i]), (sy[i], oy[i])) for i in range(n)]
    if tag == 0x08:
        return [("Ray", tuple(r.f32() for _ in range(6))) for _ in range(n)]
    if tag in (0x09, 0x0A):
        return [r.u8() for _ in range(n)]
    if tag == 0x0B:
        return _u32_array(r, n)
    if tag == 0x0C:
        x, y, z = _f32_array(r, n), _f32_array(r, n), _f32_array(r, n)
        return [("Color3", x[i], y[i], z[i]) for i in range(n)]
    if tag == 0x0D:
        x, y = _f32_array(r, n), _f32_array(r, n)
        return [("Vector2", x[i], y[i]) for i in range(n)]
    if tag == 0x0E:
        x, y, z = _f32_array(r, n), _f32_array(r, n), _f32_array(r, n)
        return [("Vector3", x[i], y[i], z[i]) for i in range(n)]
    if tag == 0x10:
        rots = []
        for _ in range(n):
            rid = r.u8()
            rots.append(tuple(tuple(r.f32() for _ in range(3)) for _ in range(3))
                        if rid == 0 else BASIC_ROTATIONS[rid])
        x, y, z = _f32_array(r, n), _f32_array(r, n), _f32_array(r, n)
        return [("CFrame", (x[i], y[i], z[i]), rots[i]) for i in range(n)]
    if tag == 0x12:
        return _u32_array(r, n)
    if tag == 0x13:
        return _referents(r, n)
    if tag == 0x1A:
        rr, gg, bb = r.raw(n), r.raw(n), r.raw(n)
        return [("Color3uint8", rr[i], gg[i], bb[i]) for i in range(n)]
    if tag == 0x1B:
        return [r.i64() for _ in range(n)]
    if tag == 0x1C:
        return _u32_array(r, n)
    if tag == 0x22:  # Content
        kinds = _i32_array(r, n)
        uris = [r.string() for _ in range(r.u32())]
        objs = _referents(r, r.u32())
        r.raw(r.u32() * 4)
        out = []
        for k in kinds:
            if k == 0:
                out.append(None)
            elif k == 1:
                out.append(uris.pop(0) if uris else None)
            else:
                out.append(("ref", objs.pop(0) if objs else None))
        return out
    return None


def load(path):
    """Parse a binary place/model file. Returns (roots, metadata, instances)."""
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:8] != MAGIC:
        raise ValueError("not a binary Roblox file")
    version, num_types, num_instances, _reserved = struct.unpack_from("<HIIQ", data, 14)
    if version != 0:
        raise ValueError(f"unsupported file version {version}")

    dctx = zstd.ZstdDecompressor()
    chunks = []
    pos = 32
    while pos < len(data):
        name = data[pos:pos + 4]
        comp, uncomp, _ = struct.unpack_from("<III", data, pos + 4)
        pos += 16
        if comp == 0:
            body = data[pos:pos + uncomp]
            pos += uncomp
        else:
            body = dctx.decompress(data[pos:pos + comp], max_output_size=uncomp)
            pos += comp
        chunks.append((name, body))
        if name.startswith(b"END"):
            break

    shared_strings, metadata = [], {}
    types = {}
    instances = {}
    order = []
    pending_parents = []

    for name, body in chunks:
        if name == b"META":
            r = _Reader(body)
            for _ in range(r.u32()):
                k, v = r.string(), r.string()
                metadata[k] = v
        elif name == b"SSTR":
            r = _Reader(body)
            r.u32()
            for _ in range(r.u32()):
                r.raw(16)
                shared_strings.append(r.bytes())
        elif name == b"INST":
            r = _Reader(body)
            type_id = r.u32()
            cls = r.string()
            fmt = r.u8()
            count = r.u32()
            refs = _referents(r, count)
            group = []
            for ref in refs:
                inst = Instance(ref, cls)
                instances[ref] = inst
                group.append(inst)
                order.append(inst)
            types[type_id] = {"cls": cls, "insts": group}
        elif name == b"PROP":
            r = _Reader(body)
            type_id = r.u32()
            prop = r.string()
            info = types.get(type_id)
            if info is None or r.pos >= len(body):
                continue
            tag = r.u8()
            group = info["insts"]
            if prop == "Name":
                for inst in group:
                    inst.name = r.string()
                continue
            try:
                values = _decode_prop(r, tag, len(group))
            except (KeyError, struct.error):
                continue
            if values is None:
                continue
            for inst, val in zip(group, values):
                inst.props[prop] = val
        elif name == b"PRNT":
            r = _Reader(body)
            r.u8()
            count = r.u32()
            subs = _referents(r, count)
            pars = _referents(r, count)
            pending_parents.extend(zip(subs, pars))

    for sub, par in pending_parents:
        inst = instances.get(sub)
        if inst is None:
            continue
        if par == -1:
            inst.parent = None
        else:
            parent = instances.get(par)
            if parent is not None:
                inst.parent = parent
                parent.children.append(inst)

    roots = [i for i in order if i.parent is None]
    return roots, metadata, instances
