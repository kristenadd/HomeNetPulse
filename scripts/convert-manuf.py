#!/usr/bin/env python3
"""Convert Wireshark's `manuf` file into HomeNetPulse/Resources/manuf.tsv.

Output lines: <hex prefix>\t<manufacturer>, where the prefix is 6 hex digits for a /24
(MA-L), 7 for a /28 (MA-M) or 9 for a /36 (MA-S). Usage:
    python3 -I scripts/convert-manuf.py path/to/manuf HomeNetPulse/Resources/manuf.tsv
"""
import re
import sys

SUFFIX = re.compile(
    r"[,.]?\s+(inc\.?|incorporated|corp\.?|corporation|co\.?,?\s*ltd\.?|company|co\.?|ltd\.?|limited|"
    r"llc\.?|l\.l\.c\.|gmbh(\s*&\s*co\.?\s*kg)?|ag|s\.?a\.?|s\.?a\.?s\.?|s\.?p\.?a\.?|b\.?v\.?|n\.?v\.?|"
    r"pty\.?|plc\.?|oy|ab|as|a/s|srl|s\.r\.l\.|kg|k\.k\.)$",
    re.IGNORECASE,
)


def clean(name: str) -> str:
    name = name.strip().strip('"').strip()
    for _ in range(4):  # "Foo Co., Ltd." needs a couple of passes
        new = SUFFIX.sub("", name).strip().rstrip(",").strip()
        if new == name or not new:
            break
        name = new
    return name


def main(src: str, dst: str) -> None:
    out = {}
    with open(src, encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.strip() or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.rstrip("\n").split("\t")]
            if len(parts) < 2:
                continue
            prefix, short = parts[0], parts[1]
            long_name = parts[2] if len(parts) > 2 and parts[2] else short
            bits = 24
            if "/" in prefix:
                prefix, b = prefix.split("/")
                bits = int(b)
            hexstr = prefix.replace(":", "").replace("-", "").upper()
            digits = {24: 6, 28: 7, 36: 9}.get(bits)
            if not digits or len(hexstr) < digits:
                continue
            name = clean(long_name) or short
            out[hexstr[:digits]] = name
    with open(dst, "w", encoding="utf-8") as f:
        f.write("# Manufacturer prefixes from Wireshark's manuf (IEEE registry). Regenerate with scripts/update-manuf.sh\n")
        for k in sorted(out):
            f.write(f"{k}\t{out[k]}\n")
    print(f"wrote {len(out)} prefixes to {dst}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
