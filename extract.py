#!/usr/bin/env python3
"""
Alien TxtBase — Turbo Extractor v3
Full ULP mode: keeps URL:Email:Password combos (not just emails).
Multi-core, optimized for 500GB+ datasets.
Zero duplicates on full lines.

Usage:
  python3 extract.py                          # Interactive mode
  python3 extract.py -d target.com -n 5000    # Filter by domain
  python3 extract.py -d .ch                   # All Swiss
  python3 extract.py --all                    # Dedup entire base (no filter)
  python3 extract.py --index                  # Index by domain
"""

import os
import sys
import re
import time
import argparse
import multiprocessing as mp
from multiprocessing import Pool
import subprocess
import json
import hashlib
from datetime import datetime

VERSION = "3.0"
DATA_DIR = "./data"
INDEX_DIR = "./index"
RESULTS_DIR = "./results"
EMAIL_RE = re.compile(rb'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}')

G = "\033[92m"; R = "\033[91m"; Y = "\033[93m"; C = "\033[96m"
W = "\033[0m"; B = "\033[1m"; DIM = "\033[2m"; MAG = "\033[95m"


def banner():
    print(f"""{C}{B}
    ╔══════════════════════════════════════════════════╗
    ║   ALIEN TXTBASE — Turbo Extractor v{VERSION}           ║
    ║   Full ULP • Multi-Core • Zero Duplicates        ║
    ╚══════════════════════════════════════════════════╝{W}
    """)


def fmt_size(b):
    for u in ["B", "KB", "MB", "GB", "TB"]:
        if b < 1024: return f"{b:.1f}{u}"
        b /= 1024
    return f"{b:.1f}PB"


def fmt_num(n):
    if n >= 1_000_000_000: return f"{n/1_000_000_000:.2f}B"
    if n >= 1_000_000: return f"{n/1_000_000:.1f}M"
    if n >= 1_000: return f"{n/1_000:.1f}K"
    return str(n)


def fmt_time(s):
    if s < 60: return f"{s:.1f}s"
    if s < 3600: return f"{int(s//60)}m{int(s%60)}s"
    return f"{int(s//3600)}h{int((s%3600)//60)}m"


def get_cpu_count():
    try:
        return max(1, mp.cpu_count() - 1)
    except Exception:
        return 4


# ═══════════════════════════════════════════════════════
#  ARCHIVE HANDLER
# ═══════════════════════════════════════════════════════

def find_archives(directory):
    exts = (".rar", ".zip", ".gz", ".7z", ".tar.gz", ".tgz")
    archives = []
    for root, dirs, files in os.walk(directory):
        for f in files:
            if any(f.lower().endswith(e) for e in exts):
                archives.append(os.path.join(root, f))
    return archives


def extract_archive(archive_path, dest_dir):
    ext = archive_path.lower()
    try:
        if ext.endswith(".rar"):
            subprocess.run(["unrar", "x", "-o+", archive_path, dest_dir],
                         capture_output=True, timeout=3600)
        elif ext.endswith(".zip"):
            subprocess.run(["unzip", "-o", archive_path, "-d", dest_dir],
                         capture_output=True, timeout=3600)
        elif ext.endswith(".gz") or ext.endswith(".tgz"):
            subprocess.run(["tar", "xzf", archive_path, "-C", dest_dir],
                         capture_output=True, timeout=3600)
        elif ext.endswith(".7z"):
            subprocess.run(["7z", "x", archive_path, f"-o{dest_dir}", "-y"],
                         capture_output=True, timeout=3600)
        return True
    except Exception as e:
        print(f"  {R}Extract error: {e}{W}")
        return False


def auto_extract_all(data_dir):
    archives = find_archives(data_dir)
    if not archives:
        return
    print(f"\n  {Y}Found {len(archives)} archives to extract{W}")
    for i, arc in enumerate(archives):
        name = os.path.basename(arc)
        print(f"  {DIM}[{i+1}/{len(archives)}] Extracting {name}...{W}", end="", flush=True)
        if extract_archive(arc, data_dir):
            print(f"\r  {G}✓{W} {name}                              ")
        else:
            print(f"\r  {R}✗{W} {name}                              ")


# ═══════════════════════════════════════════════════════
#  FILE SCANNER
# ═══════════════════════════════════════════════════════

def find_txt_files(directory):
    skip = {"requirements.txt", "README.md", "readme.md"}
    files = []
    for root, dirs, filenames in os.walk(directory):
        dirs[:] = [d for d in dirs if d not in ("index", "results", ".git", "__pycache__")]
        for f in filenames:
            if f.endswith(".txt") and f not in skip:
                path = os.path.join(root, f)
                try:
                    size = os.path.getsize(path)
                    if size > 0:
                        files.append((path, size))
                except OSError:
                    pass
    files.sort(key=lambda x: -x[1])
    return files


def get_file_chunks(filepath, filesize, num_chunks):
    chunk_sz = max(filesize // num_chunks, 1024 * 1024)
    chunks = []
    for i in range(0, filesize, chunk_sz):
        end = min(i + chunk_sz, filesize)
        chunks.append((filepath, i, end))
    return chunks


# ═══════════════════════════════════════════════════════
#  VALIDATION
# ═══════════════════════════════════════════════════════

def is_valid_ulp_line(line):
    """Check if line looks like a valid ULP (has URL-like part + email + something after)."""
    if b"@" not in line or b"." not in line:
        return False
    # Must have at least 2 colons (URL:Email:Pass) or 1 (Email:Pass)
    if line.count(b":") < 1:
        return False
    # Must contain an email
    if not EMAIL_RE.search(line):
        return False
    # Minimum length (at least email + something)
    if len(line.strip()) < 10:
        return False
    return True


# ═══════════════════════════════════════════════════════
#  MODE 1: FULL DEDUP (no domain filter)
# ═══════════════════════════════════════════════════════

def process_chunk_dedup(args):
    """Process chunk — keep full lines, dedup via hash."""
    filepath, start, end = args
    seen_hashes = set()
    unique_lines = []
    lines_read = 0
    dupes = 0

    try:
        with open(filepath, "rb") as f:
            if start > 0:
                f.seek(start - 1)
                f.readline()
            else:
                f.seek(0)

            while f.tell() < end:
                line = f.readline()
                if not line:
                    break
                lines_read += 1

                line = line.strip()
                if not line or not is_valid_ulp_line(line):
                    continue

                # Hash the line for dedup (faster than storing full lines)
                h = hashlib.md5(line).digest()
                if h not in seen_hashes:
                    seen_hashes.add(h)
                    unique_lines.append(line)
                else:
                    dupes += 1

    except (OSError, ValueError):
        pass

    return unique_lines, lines_read, dupes


def process_chunk_domain(args):
    """Process chunk — filter by domain, keep full ULP lines."""
    filepath, start, end, domain_filter = args
    seen_hashes = set()
    unique_lines = []
    lines_read = 0
    domain_bytes = domain_filter.encode("utf-8")

    try:
        with open(filepath, "rb") as f:
            if start > 0:
                f.seek(start - 1)
                f.readline()
            else:
                f.seek(0)

            while f.tell() < end:
                line = f.readline()
                if not line:
                    break
                lines_read += 1

                line_stripped = line.strip()
                if not line_stripped:
                    continue

                # Quick pre-filter
                if domain_bytes not in line_stripped.lower():
                    continue

                if not is_valid_ulp_line(line_stripped):
                    continue

                h = hashlib.md5(line_stripped).digest()
                if h not in seen_hashes:
                    seen_hashes.add(h)
                    unique_lines.append(line_stripped)

    except (OSError, ValueError):
        pass

    return unique_lines, lines_read


# ═══════════════════════════════════════════════════════
#  EXTRACT WITH DOMAIN FILTER
# ═══════════════════════════════════════════════════════

def extract_domain_full(files, domain_filter, max_lines, num_workers):
    """Multi-core extraction — full ULP lines filtered by domain."""

    domain_filter = domain_filter.lower().strip()
    domain_filter = re.sub(r'^https?://', '', domain_filter)
    domain_filter = domain_filter.split("/")[0].strip(".")

    all_hashes = set()
    all_lines = []
    total_lines_read = 0
    start_time = time.time()

    print(f"\n  {C}Target:{W}     {B}{domain_filter}{W}")
    print(f"  {C}Max:{W}        {B}{fmt_num(max_lines)}{W} combos")
    print(f"  {C}Workers:{W}    {B}{num_workers}{W} CPU cores")
    print(f"  {C}Mode:{W}       {B}Full ULP (URL:Email:Pass){W}")
    print(f"  {'─' * 55}")

    for file_idx, (filepath, filesize) in enumerate(files):
        if len(all_lines) >= max_lines:
            break

        fname = os.path.basename(filepath)
        file_start = time.time()
        print(f"\n  {DIM}[{file_idx+1}/{len(files)}] {fname} ({fmt_size(filesize)}){W}")

        chunks = get_file_chunks(filepath, filesize, num_workers * 2)
        chunk_args = [(fp, s, e, domain_filter) for fp, s, e in chunks]

        file_new = 0
        file_lines = 0

        with Pool(num_workers) as pool:
            for i, (unique_lines, lines_read) in enumerate(pool.imap_unordered(process_chunk_domain, chunk_args)):
                file_lines += lines_read

                for line in unique_lines:
                    h = hashlib.md5(line).digest()
                    if h not in all_hashes:
                        all_hashes.add(h)
                        all_lines.append(line)
                        file_new += 1
                        if len(all_lines) >= max_lines:
                            break

                pct = ((i + 1) / len(chunks)) * 100
                elapsed = time.time() - file_start
                speed = file_lines / elapsed if elapsed > 0 else 0
                print(f"\r    {C}Progress:{W} {pct:5.1f}% | {fmt_num(file_lines)} lines ({fmt_num(speed)}/s) | {G}{file_new}{W} new combos   ", end="", flush=True)

                if len(all_lines) >= max_lines:
                    pool.terminate()
                    break

        total_lines_read += file_lines
        elapsed = time.time() - file_start
        print(f"\r    {G}✓{W} {fmt_num(file_lines)} lines in {fmt_time(elapsed)} | {G}+{file_new}{W} new (total: {B}{len(all_lines)}{W})          ")

        if len(all_lines) >= max_lines:
            print(f"\n  {Y}Limit reached ({fmt_num(max_lines)}){W}")
            break

    total_time = time.time() - start_time
    return all_lines, total_lines_read, total_time


# ═══════════════════════════════════════════════════════
#  FULL DEDUP MODE (no filter — entire base)
# ═══════════════════════════════════════════════════════

def dedup_full(files, max_lines, num_workers, output_file):
    """Dedup entire base — all valid ULP lines, no domain filter."""

    all_hashes = set()
    total_lines_read = 0
    total_dupes = 0
    total_unique = 0
    start_time = time.time()

    print(f"\n  {MAG}{B}FULL DEDUP MODE{W} — Keeping all unique URL:Email:Pass combos")
    print(f"  {C}Max:{W}        {B}{fmt_num(max_lines)}{W} combos")
    print(f"  {C}Workers:{W}    {B}{num_workers}{W} CPU cores")
    print(f"  {C}Output:{W}     {B}{output_file}{W}")
    print(f"  {'─' * 55}")

    # Write directly to file to avoid RAM overflow on 2.8B lines
    os.makedirs(os.path.dirname(output_file) if os.path.dirname(output_file) else ".", exist_ok=True)
    out_f = open(output_file, "wb")

    for file_idx, (filepath, filesize) in enumerate(files):
        if total_unique >= max_lines:
            break

        fname = os.path.basename(filepath)
        file_start = time.time()
        print(f"\n  {DIM}[{file_idx+1}/{len(files)}] {fname} ({fmt_size(filesize)}){W}")

        chunks = get_file_chunks(filepath, filesize, num_workers * 2)
        chunk_args = [(fp, s, e) for fp, s, e in chunks]

        file_new = 0
        file_dupes = 0
        file_lines = 0

        with Pool(num_workers) as pool:
            for i, (unique_lines, lines_read, dupes) in enumerate(pool.imap_unordered(process_chunk_dedup, chunk_args)):
                file_lines += lines_read
                file_dupes += dupes

                for line in unique_lines:
                    h = hashlib.md5(line).digest()
                    if h not in all_hashes:
                        all_hashes.add(h)
                        out_f.write(line + b"\n")
                        total_unique += 1
                        file_new += 1
                        if total_unique >= max_lines:
                            break

                pct = ((i + 1) / len(chunks)) * 100
                elapsed = time.time() - file_start
                speed = file_lines / elapsed if elapsed > 0 else 0
                print(f"\r    {C}Progress:{W} {pct:5.1f}% | {fmt_num(file_lines)} lines ({fmt_num(speed)}/s) | {G}+{fmt_num(file_new)}{W} unique | {R}{fmt_num(file_dupes)}{W} dupes   ", end="", flush=True)

                if total_unique >= max_lines:
                    pool.terminate()
                    break

        total_lines_read += file_lines
        total_dupes += file_dupes
        elapsed = time.time() - file_start
        print(f"\r    {G}✓{W} {fmt_num(file_lines)} lines in {fmt_time(elapsed)} | {G}+{fmt_num(file_new)}{W} unique | {R}{fmt_num(file_dupes)}{W} dupes          ")

        if total_unique >= max_lines:
            print(f"\n  {Y}Limit reached ({fmt_num(max_lines)}){W}")
            break

    out_f.close()
    total_time = time.time() - start_time

    out_size = os.path.getsize(output_file)

    print(f"\n  {'═' * 55}")
    print(f"  {B}DEDUP COMPLETE{W}")
    print(f"  {C}Lignes scannées:{W}    {total_lines_read:,}")
    print(f"  {G}Combos uniques:{W}     {total_unique:,}")
    print(f"  {R}Doublons supprimés:{W} {total_dupes:,}")
    print(f"  {C}Taille output:{W}      {fmt_size(out_size)}")
    print(f"  {C}Temps:{W}              {fmt_time(total_time)}")
    print(f"  {G}{B}→ {output_file}{W}")

    return total_unique, total_lines_read, total_time


# ═══════════════════════════════════════════════════════
#  INDEX MODE
# ═══════════════════════════════════════════════════════

def process_chunk_index(args):
    """Process chunk for indexing — group full lines by email domain."""
    filepath, start, end = args
    domain_map = {}
    lines_read = 0

    try:
        with open(filepath, "rb") as f:
            if start > 0:
                f.seek(start - 1)
                f.readline()
            else:
                f.seek(0)

            while f.tell() < end:
                line = f.readline()
                if not line:
                    break
                lines_read += 1

                line_stripped = line.strip()
                if not line_stripped or not is_valid_ulp_line(line_stripped):
                    continue

                # Find email domain
                emails = EMAIL_RE.findall(line_stripped)
                if not emails:
                    continue

                em = emails[0].lower()
                try:
                    domain = em.split(b"@")[1].decode("utf-8", errors="ignore")
                except (ValueError, UnicodeDecodeError):
                    continue

                h = hashlib.md5(line_stripped).digest()
                if domain not in domain_map:
                    domain_map[domain] = {}
                domain_map[domain][h] = line_stripped

    except (OSError, ValueError):
        pass

    # Convert to serializable format
    result = {}
    for d, hmap in domain_map.items():
        result[d] = list(hmap.values())
    return result, lines_read


def build_index(files, num_workers):
    """Index full ULP lines grouped by email domain."""
    os.makedirs(INDEX_DIR, exist_ok=True)
    total_lines = 0
    domain_hashes = {}  # domain -> set of md5 hashes
    domain_files = {}   # domain -> open file handle
    start_time = time.time()

    print(f"\n  {MAG}{B}INDEXING MODE{W} — Full ULP lines grouped by domain")
    print(f"  {C}Workers:{W}  {B}{num_workers}{W} CPU cores")
    print(f"  {C}Files:{W}    {B}{len(files)}{W}")
    print(f"  {'─' * 55}")

    for file_idx, (filepath, filesize) in enumerate(files):
        fname = os.path.basename(filepath)
        file_start = time.time()
        print(f"\n  {DIM}[{file_idx+1}/{len(files)}] {fname} ({fmt_size(filesize)}){W}")

        chunks = get_file_chunks(filepath, filesize, num_workers * 2)
        chunk_args = [(fp, s, e) for fp, s, e in chunks]
        file_lines = 0

        with Pool(num_workers) as pool:
            for i, (domain_map, lines) in enumerate(pool.imap_unordered(process_chunk_index, chunk_args)):
                file_lines += lines

                for domain, lines_list in domain_map.items():
                    if domain not in domain_hashes:
                        domain_hashes[domain] = set()
                        fpath = os.path.join(INDEX_DIR, domain.replace(".", "_") + ".txt")
                        domain_files[domain] = open(fpath, "ab")

                    for line in lines_list:
                        h = hashlib.md5(line).digest()
                        if h not in domain_hashes[domain]:
                            domain_hashes[domain].add(h)
                            domain_files[domain].write(line + b"\n")

                pct = ((i + 1) / len(chunks)) * 100
                elapsed = time.time() - file_start
                speed = file_lines / elapsed if elapsed > 0 else 0
                print(f"\r    {C}Progress:{W} {pct:5.1f}% | {fmt_num(file_lines)} lines ({fmt_num(speed)}/s) | {MAG}{len(domain_hashes)}{W} domains   ", end="", flush=True)

        total_lines += file_lines
        elapsed = time.time() - file_start
        print(f"\r    {G}✓{W} {fmt_num(file_lines)} lines in {fmt_time(elapsed)} | {MAG}{len(domain_hashes)}{W} domains total          ")

    # Close all files
    for f in domain_files.values():
        f.close()

    # Save summary
    summary = {d: len(hashes) for d, hashes in domain_hashes.items()}
    with open(os.path.join(INDEX_DIR, "_summary.json"), "w") as f:
        json.dump({
            "created": datetime.now().isoformat(),
            "total_lines": total_lines,
            "total_domains": len(summary),
            "total_combos": sum(summary.values()),
            "time_seconds": time.time() - start_time,
            "mode": "full_ulp",
            "domains": summary
        }, f, indent=2)

    total_time = time.time() - start_time
    total_combos = sum(summary.values())

    print(f"\n  {'═' * 55}")
    print(f"  {B}INDEX COMPLETE{W}")
    print(f"  {C}Lignes:{W}     {total_lines:,}")
    print(f"  {G}Combos:{W}     {total_combos:,}")
    print(f"  {MAG}Domaines:{W}   {len(summary):,}")
    print(f"  {C}Temps:{W}      {fmt_time(total_time)}")
    print(f"\n  {G}Top 20 domaines:{W}")
    for i, (dom, count) in enumerate(sorted(summary.items(), key=lambda x: -x[1])[:20]):
        print(f"    {DIM}{i+1:>3}.{W} {dom:<35} {G}{count:>10,}{W}")

    return summary


def query_index(domain_filter, max_lines):
    """Query pre-built index — returns full ULP lines."""
    summary_path = os.path.join(INDEX_DIR, "_summary.json")
    if not os.path.exists(summary_path):
        return None

    domain_filter = domain_filter.lower().strip()
    domain_filter = re.sub(r'^https?://', '', domain_filter)
    domain_filter = domain_filter.split("/")[0].strip(".")

    with open(summary_path) as f:
        summary = json.load(f)

    matching = [(d, c) for d, c in summary["domains"].items() if domain_filter in d]
    if not matching:
        return []

    matching.sort(key=lambda x: -x[1])
    print(f"\n  {G}Domaines matchés:{W}")
    for dom, count in matching[:10]:
        print(f"    {DIM}•{W} {dom} — {G}{count:,}{W} combos")

    lines = []
    for dom, count in matching:
        domain_file = os.path.join(INDEX_DIR, dom.replace(".", "_") + ".txt")
        if os.path.exists(domain_file):
            with open(domain_file, "rb") as f:
                for line in f:
                    lines.append(line.strip())
                    if len(lines) >= max_lines:
                        break
        if len(lines) >= max_lines:
            break
    return lines


# ═══════════════════════════════════════════════════════
#  EXPORT
# ═══════════════════════════════════════════════════════

def export_results(lines, label):
    """Save results to file."""
    os.makedirs(RESULTS_DIR, exist_ok=True)
    clean = re.sub(r'[^a-zA-Z0-9]', '_', label)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    outfile = os.path.join(RESULTS_DIR, f"combos_{clean}_{len(lines)}_{ts}.txt")

    with open(outfile, "wb") as f:
        for line in lines:
            if isinstance(line, str):
                f.write(line.encode("utf-8") + b"\n")
            else:
                f.write(line + b"\n")
    return outfile


# ═══════════════════════════════════════════════════════
#  INTERACTIVE MODE
# ═══════════════════════════════════════════════════════

def interactive_mode():
    banner()
    num_workers = get_cpu_count()
    print(f"  {C}Data dir:{W} {os.path.abspath(DATA_DIR)}")

    if not os.path.isdir(DATA_DIR):
        os.makedirs(DATA_DIR, exist_ok=True)
        print(f"  {Y}Dossier créé.{W} Place tes fichiers dedans.")
        sys.exit(0)

    auto_extract_all(DATA_DIR)
    files = find_txt_files(DATA_DIR)
    if not files:
        print(f"  {R}Aucun fichier trouvé dans {DATA_DIR}/{W}")
        sys.exit(1)

    total_size = sum(s for _, s in files)
    print(f"  {G}Fichiers:{W}  {len(files)} ({fmt_size(total_size)})")
    print(f"  {C}CPU:{W}       {num_workers} cores\n")

    has_index = os.path.exists(os.path.join(INDEX_DIR, "_summary.json"))

    print(f"  {B}Mode:{W}")
    print(f"    {C}1.{W} Extraire combos par domaine (URL:Email:Pass)")
    if has_index:
        print(f"    {C}2.{W} Extraire combos par domaine {G}(via index — INSTANT){W}")
    print(f"    {C}3.{W} Indexer toute la base (par domaine)")
    print(f"    {C}4.{W} Dedup complet (toute la base, sans filtre)")
    print(f"    {C}5.{W} Stats de l'index")
    print()

    choice = input(f"  {C}Choix [1-5]:{W} ").strip()

    if choice == "1":
        domain = input(f"  {C}Domaine cible{W} (ex: target.com): ").strip()
        if not domain:
            sys.exit(1)
        max_str = input(f"  {C}Max combos ?{W} {DIM}(défaut: all){W}: ").strip()
        max_lines = int(max_str) if max_str.isdigit() else 999_999_999

        lines, total_read, elapsed = extract_domain_full(files, domain, max_lines, num_workers)
        if lines:
            outfile = export_results(lines, domain)
            print(f"\n  {'═' * 55}")
            print(f"  {G}Combos uniques:{W}   {len(lines):,}")
            print(f"  {C}Temps:{W}            {fmt_time(elapsed)}")
            print(f"  {G}{B}→ {outfile}{W}\n")
        else:
            print(f"\n  {R}Aucun résultat.{W}\n")

    elif choice == "2" and has_index:
        domain = input(f"  {C}Domaine cible{W}: ").strip()
        if not domain:
            sys.exit(1)
        max_str = input(f"  {C}Max combos ?{W} {DIM}(défaut: all){W}: ").strip()
        max_lines = int(max_str) if max_str.isdigit() else 999_999_999

        start = time.time()
        lines = query_index(domain, max_lines)
        elapsed = time.time() - start
        if lines:
            outfile = export_results(lines, domain)
            print(f"\n  {G}{B}✓ {len(lines):,} combos en {elapsed:.2f}s → {outfile}{W}\n")
        else:
            print(f"\n  {R}Aucun résultat.{W}\n")

    elif choice == "3":
        confirm = input(f"\n  {Y}Indexer {fmt_size(total_size)} ? (o/n):{W} ").strip().lower()
        if confirm in ("o", "oui", "y", "yes"):
            build_index(files, num_workers)

    elif choice == "4":
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        outfile = os.path.join(RESULTS_DIR, f"full_dedup_{ts}.txt")
        max_str = input(f"  {C}Max combos ?{W} {DIM}(défaut: all){W}: ").strip()
        max_lines = int(max_str) if max_str.isdigit() else 999_999_999
        confirm = input(f"\n  {Y}Dedup {fmt_size(total_size)} complet → {outfile} ? (o/n):{W} ").strip().lower()
        if confirm in ("o", "oui", "y", "yes"):
            dedup_full(files, max_lines, num_workers, outfile)

    elif choice == "5":
        summary_path = os.path.join(INDEX_DIR, "_summary.json")
        if os.path.exists(summary_path):
            with open(summary_path) as f:
                s = json.load(f)
            print(f"\n  {B}INDEX STATS{W}")
            print(f"  {C}Créé:{W}      {s['created']}")
            print(f"  {G}Combos:{W}    {s['total_combos']:,}")
            print(f"  {MAG}Domaines:{W}  {s['total_domains']:,}")
            mode = s.get('mode', 'email_only')
            print(f"  {C}Mode:{W}      {mode}")
            print(f"\n  {G}Top 30:{W}")
            for i, (dom, count) in enumerate(sorted(s['domains'].items(), key=lambda x: -x[1])[:30]):
                print(f"    {DIM}{i+1:>3}.{W} {dom:<35} {G}{count:>10,}{W}")
        else:
            print(f"  {R}Pas d'index.{W}")


# ═══════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(description="Alien TxtBase Extractor v3 — Full ULP")
    parser.add_argument("-d", "--domain", help="Domain to filter")
    parser.add_argument("-n", "--max", type=int, default=999999999, help="Max combos")
    parser.add_argument("-w", "--workers", type=int, default=0, help="CPU workers (0=auto)")
    parser.add_argument("--index", action="store_true", help="Build full index")
    parser.add_argument("--query", action="store_true", help="Query existing index")
    parser.add_argument("--all", action="store_true", help="Full dedup (no filter)")
    parser.add_argument("-o", "--output", default="", help="Output file for --all mode")
    parser.add_argument("--data", default="./data", help="Data directory")
    args = parser.parse_args()

    global DATA_DIR, INDEX_DIR, RESULTS_DIR
    DATA_DIR = args.data
    INDEX_DIR = os.path.join(os.path.dirname(args.data.rstrip("/")), "index")
    RESULTS_DIR = os.path.join(os.path.dirname(args.data.rstrip("/")), "results")

    if not args.domain and not args.index and not args.query and not args.all:
        interactive_mode()
        return

    banner()
    num_workers = args.workers if args.workers > 0 else get_cpu_count()
    auto_extract_all(DATA_DIR)
    files = find_txt_files(DATA_DIR)
    if not files:
        print(f"  {R}No files found{W}")
        sys.exit(1)

    total_size = sum(s for _, s in files)
    print(f"  {C}Files:{W} {len(files)} ({fmt_size(total_size)}) | {C}Workers:{W} {num_workers}")

    if args.index:
        build_index(files, num_workers)

    elif args.all:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        outfile = args.output or os.path.join(RESULTS_DIR, f"full_dedup_{ts}.txt")
        dedup_full(files, args.max, num_workers, outfile)

    elif args.query and args.domain:
        lines = query_index(args.domain, args.max)
        if lines:
            outfile = export_results(lines, args.domain)
            print(f"  {G}✓ {len(lines):,} combos → {outfile}{W}")

    elif args.domain:
        lines, total_read, elapsed = extract_domain_full(files, args.domain, args.max, num_workers)
        if lines:
            outfile = export_results(lines, args.domain)
            print(f"\n  {G}✓ {len(lines):,} combos in {fmt_time(elapsed)} → {outfile}{W}")


if __name__ == "__main__":
    main()
