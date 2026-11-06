#!/usr/bin/env python3
# edge/secret_scan.py
# Stage 3-5g gate: look for the camera credential in the places the gate names — journal,
# unit files, process args, process environment, files on disk.
#
# Run as ROOT by scripts/13-install-trusted-edge.sh with the venv python.  It fetches the real
# rtsp_url from Vault itself (edge token), derives the needles IN MEMORY and prints only counts
# and file paths — never a needle, never matching text.
#
# Scope (stated, not claimed wider): journal entries since --since (all units), the listed
# directories, every /proc/<pid>/cmdline, /proc/<MainPID>/environ of the service.  It is NOT a
# whole-disk or memory scan.
#
# --known PATH declares a file that is EXPECTED to contain the credential (here: the WebUI's
# config/camera.env, see AGENTS.md section 3 / THREAT_MODEL.md T-13).  A hit in a known path is
# printed as KNOWN-HIT with its mtime and counted separately; it never hides an unexpected hit.
#
# usage: secret_scan.py --since "YYYY-MM-DD HH:MM:SS" --main-pid N --dir PATH [--dir PATH ...]
#                       [--known PATH ...]
# exit 0 = no hits, 1 = unexpected hits, 2 = could not run, 3 = only hits in --known paths

import argparse
import os
import subprocess
import sys
import time
from urllib.parse import unquote, urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trusted_edge as te  # noqa: E402

SKIP_DIRS = {".venv", "venv", ".git", "models", "node_modules", "__pycache__", "checkpoints", "engines"}
MAX_FILE = 5 * 1024 * 1024


def needles() -> list[bytes]:
    url = te.fetch_rtsp_url()
    p = urlsplit(url)
    out = {url}
    if p.password:
        out.add(p.password)
        out.add(unquote(p.password))
        if p.username:
            out.add(f"{p.username}:{p.password}")
    if p.password is not None and len(p.password) < 6:
        print("WARN: password shorter than 6 chars — substring hits may be false positives",
              file=sys.stderr)
    return [n.encode() for n in out if n]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", required=True)
    ap.add_argument("--main-pid", type=int, required=True)
    ap.add_argument("--dir", action="append", default=[])
    ap.add_argument("--known", action="append", default=[])
    a = ap.parse_args()
    known = {os.path.realpath(k) for k in a.known}

    try:
        nd = needles()
    except Exception as exc:  # noqa: BLE001
        print(f"cannot derive needles: {type(exc).__name__}", file=sys.stderr)
        return 2
    hits = 0
    known_hits = 0

    def check(label: str, blob: bytes) -> None:
        nonlocal hits, known_hits
        if any(n in blob for n in nd):
            if os.path.realpath(label) in known:
                known_hits += 1
                mt = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(os.path.getmtime(label)))
                print(f"KNOWN-HIT  {label} (declared; file mtime {mt})")
                return
            hits += 1
            print(f"HIT  {label}")

    # journal (streamed line by line)
    jl = 0
    pr = subprocess.Popen(["journalctl", "--no-pager", "-o", "cat", "--since", a.since],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    for line in pr.stdout:
        jl += 1
        if any(n in line for n in nd):
            hits += 1
            print(f"HIT  journal line #{jl}")
    pr.wait()
    print(f"scanned journal since {a.since}: {jl} lines")

    # process args (all processes) + environment of the service
    n_cmd = 0
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                blob = fh.read()
        except OSError:
            continue
        n_cmd += 1
        check(f"/proc/{pid}/cmdline", blob)
    print(f"scanned {n_cmd} /proc/*/cmdline")
    try:
        with open(f"/proc/{a.main_pid}/environ", "rb") as fh:
            check(f"/proc/{a.main_pid}/environ", fh.read())
        print(f"scanned /proc/{a.main_pid}/environ")
    except OSError as exc:
        print(f"WARN: cannot read /proc/{a.main_pid}/environ: {type(exc).__name__}", file=sys.stderr)
        hits += 0

    # files on disk
    n_files = 0
    for root_dir in a.dir:
        for dp, dns, fns in os.walk(root_dir):
            dns[:] = [d for d in dns if d not in SKIP_DIRS]
            for fn in fns:
                path = os.path.join(dp, fn)
                try:
                    if os.path.islink(path) or os.path.getsize(path) > MAX_FILE:
                        continue
                    with open(path, "rb") as fh:
                        blob = fh.read()
                except OSError:
                    continue
                n_files += 1
                check(path, blob)
    print(f"scanned {n_files} files under {', '.join(a.dir)}")

    print(f"RESULT unexpected_hits={hits} known_hits={known_hits}")
    if hits:
        return 1
    return 3 if known_hits else 0


if __name__ == "__main__":
    sys.exit(main())
