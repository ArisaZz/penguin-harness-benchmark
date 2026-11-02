#!/usr/bin/env bash
# Replace the two Git LFS pointer files in data/penguinharness-benchmark-sec-a/upstream/
# (downloaded by fetch.sh) with the objects they point to.
#
# For maintainers only, after tools/rag_bench/fetch.sh: the GitHub archive carries LFS
# pointers, not the objects, for the payloads of longda_nscg_telework_hard and
# spider2lite_f1_overtake_audit_hard. This asks the upstream repository's public LFS batch
# API for each object (no token needed), follows the download link it returns, checks the
# SHA-256 and size against the pinned pointer, and only then replaces the pointer.
# Standard library Python only. Safe to re-run: a payload already in place is checked and
# left alone. convert.py then commits those two files xz-compressed (see SOURCE.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEST="$ROOT/data/penguinharness-benchmark-sec-a/upstream"
if [[ ! -f "$DEST/.fetched-commit" ]]; then
  echo "$DEST is missing; run tools/rag_bench/fetch.sh first" >&2
  exit 1
fi

python3 - "$DEST" <<'EOF'
import hashlib
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

UPSTREAM = Path(sys.argv[1])
BATCH_URL = "https://github.com/Prism-Shadow/rag-bench-essential.git/info/lfs/objects/batch"
LFS_JSON = "application/vnd.git-lfs+json"
# The pointers at the pinned commit (979adae): path -> (sha256 oid, size in bytes).
OBJECTS = {
    "cases/longda_nscg_telework_hard/data/epcg23.csv": (
        "41b626b26dc63fd0fa4a24d290c3dd5b3bd363a7444b597a17f8d771856d5791",
        144472563,
    ),
    "cases/spider2lite_f1_overtake_audit_hard/data/f1.sqlite": (
        "35ad3b824678e8435bde02f14bcd554630792874749fdd59fe9ca1385234ce23",
        74940416,
    ),
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def pointer_fields(path: Path) -> dict[str, str] | None:
    if path.stat().st_size > 1024:
        return None
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    fields = dict(line.split(" ", 1) for line in lines if " " in line)
    return fields if fields.get("version") == "https://git-lfs.github.com/spec/v1" else None


def with_retries(what: str, action):
    for attempt in range(1, 6):
        try:
            return action()
        except OSError as exc:
            print(f"{what}: attempt {attempt} failed: {exc}", file=sys.stderr)
            time.sleep(10 * attempt)
    raise SystemExit(f"{what}: giving up")


pending = {}
for rel, (oid, size) in OBJECTS.items():
    path = UPSTREAM / rel
    if not path.is_file():
        raise SystemExit(f"{path}: missing; re-run tools/rag_bench/fetch.sh")
    fields = pointer_fields(path)
    if fields is None:
        if path.stat().st_size == size and sha256_file(path) == oid:
            print(f"{rel}: payload already in place")
            continue
        raise SystemExit(f"{path}: neither the pinned pointer nor its payload; re-run tools/rag_bench/fetch.sh")
    if fields.get("oid") != f"sha256:{oid}" or fields.get("size") != str(size):
        raise SystemExit(f"{path}: pointer differs from the pinned one ({fields.get('oid')}, {fields.get('size')})")
    pending[rel] = (oid, size)

if pending:
    body = json.dumps(
        {
            "operation": "download",
            "transfers": ["basic"],
            "objects": [{"oid": oid, "size": size} for oid, size in pending.values()],
        }
    ).encode()
    request = urllib.request.Request(
        BATCH_URL, data=body, method="POST", headers={"Accept": LFS_JSON, "Content-Type": LFS_JSON}
    )
    answer = with_retries("LFS batch request", lambda: json.load(urllib.request.urlopen(request, timeout=120)))
    actions = {}
    for item in answer.get("objects", []):
        if "error" in item:
            raise SystemExit(f"LFS object {item.get('oid')}: {item['error']}")
        actions[item["oid"]] = item["actions"]["download"]

    for rel, (oid, size) in pending.items():
        path = UPSTREAM / rel
        download = actions.get(oid)
        if download is None:
            raise SystemExit(f"{rel}: the LFS batch answer has no download for {oid}")
        partial = path.with_name(path.name + ".lfs-part")

        def fetch() -> None:
            get = urllib.request.Request(download["href"], headers=download.get("header", {}))
            with urllib.request.urlopen(get, timeout=600) as response, partial.open("wb") as out:
                while chunk := response.read(1 << 20):
                    out.write(chunk)

        with_retries(f"download of {rel}", fetch)
        if partial.stat().st_size != size or sha256_file(partial) != oid:
            partial.unlink()
            raise SystemExit(f"{rel}: downloaded object does not match the pointer's SHA-256 and size")
        os.chmod(partial, path.stat().st_mode & 0o777)
        partial.replace(path)
        print(f"{rel}: {size} bytes, sha256 {oid}")
EOF
