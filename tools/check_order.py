#!/usr/bin/env python3
"""
check_order.py -- ищет классическую ошибку Luau: использование локальной
функции/переменной ДО её объявления.

В Lua имя, встреченное раньше `local function X`, разрешается как ГЛОБАЛЬНОЕ,
поэтому такая строка падает с «attempt to call a nil value», даже если сама
функция объявлена ниже. Анализатор сообщает такие места.

Запуск: python3 tools/check_order.py
"""

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEF_PATTERNS = [
    re.compile(r"^\s*local\s+function\s+([A-Za-z_]\w*)"),
    re.compile(r"^\s*function\s+([A-Za-z_]\w*)\s*\("),
    re.compile(r"^\s*local\s+([A-Za-z_]\w*)\s*=\s*function"),
]
# «пустые» forward-объявления: local a, b, c
FWD_PATTERN = re.compile(r"^\s*local\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*$")

IGNORE = {"self", "true", "false", "nil", "and", "or", "not", "if", "then", "else",
          "elseif", "end", "function", "local", "for", "while", "do", "return",
          "repeat", "until", "break", "continue", "in"}


def strip_code_lines(text):
    """Грубо убирает комментарии и строки, чтобы не ловить ложные срабатывания."""
    out = []
    in_long_comment = False
    in_long_string = None
    for line in text.split("\n"):
        raw = line
        if in_long_string:
            idx = raw.find(in_long_string)
            if idx >= 0:
                in_long_string = None
                raw = raw[idx + 1:]
            else:
                out.append("")
                continue
        if in_long_comment:
            idx = raw.find("]]")
            if idx >= 0:
                in_long_comment = False
                raw = raw[idx + 2:]
            else:
                out.append("")
                continue
        # длинный комментарий
        m = re.search(r"--\[(=*)\[", raw)
        if m:
            end_tok = "]" + m.group(1) + "]"
            idx = raw.find(end_tok, m.end())
            if idx >= 0:
                raw = raw[:m.start()] + raw[idx + len(end_tok):]
            else:
                in_long_comment = True
                raw = raw[:m.start()]
        # длинная строка
        m = re.search(r"\[(=*)\[", raw)
        if m:
            end_tok = "]" + m.group(1) + "]"
            idx = raw.find(end_tok, m.end())
            if idx >= 0:
                raw = raw[:m.start()] + '""' + raw[idx + len(end_tok):]
            else:
                in_long_string = end_tok
                raw = raw[:m.start()] + '""'
        # короткий комментарий
        idx = raw.find("--")
        while idx >= 0:
            if raw[idx - 1:idx] in ("'", '"'):
                break
            quote_count = raw[:idx].count('"') + raw[:idx].count("'")
            if quote_count % 2 == 0:
                raw = raw[:idx]
                break
            idx = raw.find("--", idx + 2)
        # строки
        raw = re.sub(r'"(?:\\.|[^"\\])*"', '""', raw)
        raw = re.sub(r"'(?:\\.|[^'\\])*'", '""', raw)
        out.append(raw)
    return out


def check(path):
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    lines = strip_code_lines(text)

    declared_at = {}
    forwards = set()
    for number, line in enumerate(lines):
        m = FWD_PATTERN.match(line)
        if m:
            for name in m.group(1).split(","):
                name = name.strip()
                if name:
                    forwards.add(name)
                    declared_at.setdefault(name, number)
        for pattern in DEF_PATTERNS:
            m = pattern.match(line)
            if m:
                name = m.group(1)
                declared_at.setdefault(name, number)

    problems = []
    for name, def_line in declared_at.items():
        if name in IGNORE or len(name) < 2:
            continue
        pattern = re.compile(r"(?<![.:\w])" + re.escape(name) + r"\b")
        for number, line in enumerate(lines):
            if number >= def_line:
                break
            if "local" in line and re.search(r"local\s+[^=]*\b" + re.escape(name), line):
                continue
            if pattern.search(line):
                # пропускаем строки-объявления других функций с этим именем
                if re.match(r"^\s*(local\s+)?function\s+" + re.escape(name), line):
                    continue
                problems.append((number + 1, name, def_line + 1,
                                 line.strip()[:90]))
    return problems


def main():
    files = sorted(glob.glob(os.path.join(ROOT, "src", "**", "*.luau"), recursive=True))
    total = 0
    for path in files:
        rel = os.path.relpath(path, ROOT)
        problems = check(path)
        print(f"{rel:58s} {'OK' if not problems else str(len(problems)) + ' проблем'}")
        seen = set()
        for line, name, def_line, snippet in problems:
            key = (name, def_line)
            if key in seen:
                continue
            seen.add(key)
            print(f"      стр.{line:4d}  «{name}» используется до объявления (стр.{def_line})")
            print(f"              {snippet}")
        total += len(problems)
    print(f"\nвсего проблем порядка объявления: {total}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
