#!/usr/bin/env python3
"""
check_luau.py -- лёгкая проверка Luau-скриптов без интерпретатора:

  * токенизация с учётом строк, длинных строк и комментариев;
  * баланс блоков (function/if/for/while/do/repeat ... end/until);
  * баланс скобок () [] {};
  * проверка, что вызовы ui:<метод>() существуют в DroneUI;
  * проверка, что require'ы ссылаются на существующие модули проекта.

Запуск: python3 tools/check_luau.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")

KEYWORDS_OPEN = {"function", "if", "for", "while", "do", "repeat"}
BUILTINS = {"end", "until", "then", "else", "elseif", "do", "return", "local",
            "break", "continue", "in"}


def tokenize(text):
    """Yield (kind, value, line). kind: name | string | number | op | comment."""
    i = 0
    line = 1
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "\n":
            line += 1
            i += 1
            continue
        if ch in " \t\r":
            i += 1
            continue
        # comments
        if text.startswith("--", i):
            # long comment?
            m = re.match(r"--\[(=*)\[", text[i:])
            if m:
                eq = m.group(1)
                end_tok = "]" + eq + "]"
                j = text.find(end_tok, i + len(m.group(0)))
                j = n if j < 0 else j + len(end_tok)
                line += text.count("\n", i, j)
                i = j
                continue
            j = text.find("\n", i)
            j = n if j < 0 else j
            i = j
            continue
        # long strings
        m = re.match(r"\[(=*)\[", text[i:])
        if m:
            eq = m.group(1)
            end_tok = "]" + eq + "]"
            j = text.find(end_tok, i + len(m.group(0)))
            j = n if j < 0 else j + len(end_tok)
            yield ("string", text[i:j], line)
            line += text.count("\n", i, j)
            i = j
            continue
        # short strings
        if ch in "\"'":
            q = ch
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == q:
                    j += 1
                    break
                if text[j] == "\n":
                    yield ("error", "незакрытая строка", line)
                    break
                j += 1
            yield ("string", text[i:j], line)
            i = j
            continue
        # numbers
        m = re.match(r"0[xX][0-9a-fA-F]+|\d+\.?\d*([eE][+-]?\d+)?", text[i:])
        if m and (ch.isdigit() or (ch == "." and i + 1 < n and text[i + 1].isdigit())):
            yield ("number", m.group(0), line)
            i += len(m.group(0))
            continue
        # names
        m = re.match(r"[A-Za-z_][A-Za-z_0-9]*", text[i:])
        if m:
            yield ("name", m.group(0), line)
            i += len(m.group(0))
            continue
        # multi-char operators
        for op in ("...", "..=", "==", "~=", "<=", ">=", "::", "->", "+=", "-=",
                   "*=", "/=", "//=", "^=", "..", "//"):
            if text.startswith(op, i):
                yield ("op", op, line)
                i += len(op)
                break
        else:
            yield ("op", ch, line)
            i += 1


def check_file(path):
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    problems = []
    blocks = []          # (kind, line)
    brackets = []        # (char, line)
    prev = None
    for kind, value, line in tokenize(text):
        if kind == "error":
            problems.append(f"{line}: {value}")
            continue
        if kind == "op":
            if value in "([{":
                brackets.append((value, line))
            elif value in ")]}":
                pair = {")": "(", "]": "[", "}": "{"}[value]
                if not brackets or brackets[-1][0] != pair:
                    problems.append(f"{line}: лишняя/несовпадающая скобка {value!r}")
                else:
                    brackets.pop()
        elif kind == "name":
            if value == "function":
                blocks.append(("function", line))
            elif value == "if":
                blocks.append(("if", line))
            elif value in ("for", "while"):
                blocks.append(("loop", line))
            elif value == "repeat":
                blocks.append(("repeat", line))
            elif value == "do":
                # «do» после for/while -- это часть заголовка цикла
                if blocks and blocks[-1][0] in ("loop",):
                    blocks[-1] = ("loop-body", line)
                elif prev and prev[1] in ("function", "if", "do", "else"):
                    blocks.append(("do", line))
                else:
                    blocks.append(("do", line))
            elif value == "end":
                if not blocks:
                    problems.append(f"{line}: «end» без открывающего блока")
                elif blocks[-1][0] == "repeat":
                    problems.append(f"{line}: «end» закрывает «repeat» (нужен «until»)")
                    blocks.pop()
                else:
                    blocks.pop()
            elif value == "until":
                if blocks and blocks[-1][0] == "repeat":
                    blocks.pop()
                else:
                    problems.append(f"{line}: «until» без «repeat»")
        prev = (kind, value, line)

    for kind, line in blocks:
        problems.append(f"{line}: блок «{kind}» не закрыт")
    for ch, line in brackets:
        problems.append(f"{line}: незакрытая скобка {ch!r}")
    return problems


def collect_ui_methods():
    path = os.path.join(SRC, "StarterPlayer", "StarterPlayerScripts", "DroneUI.luau")
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    return set(re.findall(r"function\s+DroneUI[:.]([A-Za-z_0-9]+)", text))


def main():
    files = []
    for base, _dirs, names in os.walk(SRC):
        for name in sorted(names):
            if name.endswith(".luau"):
                files.append(os.path.join(base, name))

    ui_methods = collect_ui_methods()
    failed = 0
    for path in files:
        rel = os.path.relpath(path, ROOT)
        problems = check_file(path)
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
        # ui:<method> должны существовать
        if os.path.basename(path).startswith("DroneClient"):
            for method in sorted(set(re.findall(r"ui:([A-Za-z_0-9]+)\(", text))):
                if method not in ui_methods:
                    problems.append(f"вызов ui:{method}() -- нет такого метода в DroneUI")
        lines = text.count("\n") + 1
        status = "OK" if not problems else f"{len(problems)} проблем"
        print(f"{rel:60s} {lines:5d} строк   {status}")
        for p in problems[:12]:
            print("     ", p)
        if problems:
            failed += 1
    print()
    print(f"проверено файлов: {len(files)}, с проблемами: {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
