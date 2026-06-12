#!/usr/bin/env python3
"""Normalized manifest of a publish dir: timestamp-insensitive hashes so
runs from different times compare equal unless content really changed."""
import hashlib, os, re, subprocess, sys

TS = [
    # ISO datetimes 2026-06-11T09:45:07.123-05:00 / with space / Z
    re.compile(rb"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?([+-]\d{2}:?\d{2}|Z)?"),
    # Thu, Jun 11, 2026 09:45-0500  (kindling page footer style)
    re.compile(rb"(Mon|Tue|Wed|Thu|Fri|Sat|Sun), [A-Z][a-z]{2} \d{1,2}, \d{4} \d{2}:\d{2}([+-]\d{4})?"),
    # bare times like 09:45:07
    re.compile(rb"\b\d{2}:\d{2}:\d{2}\b"),
    # render dates like "11 Jun 2026" (expansion-generated lines on valueset pages)
    re.compile(rb"\b\d{1,2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4}\b"),
    # random UUIDs in generated html (table script ids, image names)
    re.compile(rb"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"),
    # section numbers: unstable across identical stock runs (HashMap order in vs/cs numbering)
    re.compile(rb'sectioncount">[\d.]+'),
    re.compile(rb'<a name="[\d.]+">'),
    re.compile(rb'#[\d.]+" title="link to here"'),
]
ARCHIVE = (".zip", ".jar", ".pack", ".tgz", ".xlsx")
BINARY = (".png", ".gif", ".jpg", ".jpeg", ".ico", ".eot", ".woff", ".woff2", ".ttf", ".pdf", ".epub", ".exe", ".dll", ".class")

def norm_hash(path):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        return "READ-ERROR"
    for rx in TS:
        data = rx.sub(b"TS", data)
    return hashlib.sha256(data).hexdigest()[:16]

def archive_sig(path):
    # member names + sizes (zip stores mtimes which always differ)
    try:
        if path.endswith(".tgz"):
            out = subprocess.run(["tar", "-tzf", path], capture_output=True).stdout
        else:
            p = subprocess.run(["unzip", "-l", path], capture_output=True)
            out = b"\n".join(b" ".join(l.split()[:1] + l.split()[3:4]) for l in p.stdout.splitlines()[3:-2])
    except Exception:
        return "ARCHIVE-ERROR"
    return hashlib.sha256(out).hexdigest()[:16]

def main(root):
    files = []
    for dp, dn, fn in os.walk(root):
        for n in fn:
            files.append(os.path.relpath(os.path.join(dp, n), root))
    for rel in sorted(files):
        p = os.path.join(root, rel)
        low = rel.lower()
        if low.endswith(ARCHIVE):
            h = "A:" + archive_sig(p)
        elif low.endswith(BINARY):
            h = "B:" + hashlib.sha256(open(p, "rb").read()).hexdigest()[:16]
        else:
            h = "N:" + norm_hash(p)
        print(f"{h}\t{rel}")

if __name__ == "__main__":
    main(sys.argv[1])
