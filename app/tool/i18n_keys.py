#!/usr/bin/env python3
"""Lists all tr('…') keys of lib/ (source texts to translate); --json prints them as JSON."""
import glob, json, re, sys

LIT = re.compile(r"""\s*('(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*")""")

def unescape(body):
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), body)

def keys():
    out = {}
    for f in sorted(glob.glob("lib/**/*.dart", recursive=True)):
        if "/l10n/" in f:
            continue
        src = open(f, encoding="utf-8").read()
        for m in re.finditer(r"(?<![\w.])tr\(", src):
            i, parts = m.end(), []
            while True:
                lm = LIT.match(src, i)
                if not lm:
                    break
                parts.append(unescape(lm.group(1)[1:-1]))
                i = lm.end()
            if parts:
                out.setdefault("".join(parts), f)
    return out

if __name__ == "__main__":
    k = keys()
    if "--json" in sys.argv:
        print(json.dumps(sorted(k), ensure_ascii=False, indent=0))
    else:
        print(len(k), "keys")
