#!/bin/bash
# ═══════════════════════════════════════════════════════
#  ALIEN TXTBASE — VPS Auto Setup Script
#  One-command install: torrent client + extractor + all deps
#  Tested on: Ubuntu 22.04 / 24.04
#  
#  Usage: curl -sL [url] | bash
#  Or:    chmod +x setup_vps.sh && ./setup_vps.sh
# ═══════════════════════════════════════════════════════

set -e

# Colors
G="\033[92m"; R="\033[91m"; Y="\033[93m"; C="\033[96m"
W="\033[0m"; B="\033[1m"; DIM="\033[2m"; MAG="\033[95m"

MAGNET="magnet:?xt=urn:btih:169257f30c3fbee583cc3605e9653549a59a9523&dn=ALIEN_TXTBASE&tr=udp://tracker.openbittorrent.com:80&tr=udp://tracker.opentrackr.org:1337/announce&tr=udp://open.stealth.si:80/announce&tr=udp://tracker.torrent.eu.org:451/announce&tr=udp://explodie.org:6969/announce&tr=udp://exodus.desync.com:6969/announce&tr=udp://tracker.tiny-vps.com:6969/announce&tr=udp://tracker.moeking.me:6969/announce"

WORK_DIR="/root/alien"
DATA_DIR="$WORK_DIR/data"
INDEX_DIR="$WORK_DIR/index"
RESULTS_DIR="$WORK_DIR/results"
QB_PORT=8080
QB_USER="admin"
QB_PASS="alien2024"

banner() {
    echo -e "${C}${B}"
    echo "    ╔══════════════════════════════════════════════════╗"
    echo "    ║   ALIEN TXTBASE — VPS Auto Installer             ║"
    echo "    ║   Torrent + Extractor + Full Setup               ║"
    echo "    ╚══════════════════════════════════════════════════╝"
    echo -e "${W}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "  ${R}Run as root: sudo ./setup_vps.sh${W}"
        exit 1
    fi
}

check_disk() {
    echo -e "\n  ${C}${B}[1/7] Checking disk space...${W}"
    AVAIL=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')
    echo -e "  Available: ${B}${AVAIL}GB${W}"
    
    if [ "$AVAIL" -lt 700 ]; then
        echo -e "  ${R}⚠ WARNING: Less than 700GB free.${W}"
        echo -e "  ${R}  562GB download + extraction needs ~1.5TB${W}"
        echo -e "  ${Y}  Recommended: mount a volume or get bigger disk${W}"
        echo ""
        read -p "  Continue anyway? (y/n): " CONT
        if [ "$CONT" != "y" ] && [ "$CONT" != "Y" ]; then
            exit 1
        fi
    else
        echo -e "  ${G}✓ Disk OK${W}"
    fi
}

check_ram() {
    echo -e "\n  ${C}${B}[2/7] Checking RAM...${W}"
    TOTAL_RAM=$(free -g | awk '/Mem:/{print $2}')
    CPUS=$(nproc)
    echo -e "  RAM: ${B}${TOTAL_RAM}GB${W} | CPU: ${B}${CPUS} cores${W}"
    
    if [ "$TOTAL_RAM" -lt 16 ]; then
        echo -e "  ${Y}⚠ Low RAM (${TOTAL_RAM}GB). Adding 32GB swap...${W}"
        if [ ! -f /swapfile_alien ]; then
            fallocate -l 32G /swapfile_alien
            chmod 600 /swapfile_alien
            mkswap /swapfile_alien
            swapon /swapfile_alien
            echo '/swapfile_alien none swap sw 0 0' >> /etc/fstab
            echo -e "  ${G}✓ 32GB swap added${W}"
        else
            echo -e "  ${G}✓ Swap already exists${W}"
        fi
    elif [ "$TOTAL_RAM" -lt 32 ]; then
        echo -e "  ${Y}Adding 16GB swap as safety net...${W}"
        if [ ! -f /swapfile_alien ]; then
            fallocate -l 16G /swapfile_alien
            chmod 600 /swapfile_alien
            mkswap /swapfile_alien
            swapon /swapfile_alien
            echo '/swapfile_alien none swap sw 0 0' >> /etc/fstab
            echo -e "  ${G}✓ 16GB swap added${W}"
        fi
    else
        echo -e "  ${G}✓ RAM OK (${TOTAL_RAM}GB)${W}"
    fi
}

install_deps() {
    echo -e "\n  ${C}${B}[3/7] Installing dependencies...${W}"
    
    apt-get update -qq
    apt-get install -y -qq \
        python3 python3-pip \
        qbittorrent-nox \
        unrar p7zip-full \
        screen htop iotop \
        > /dev/null 2>&1
    
    echo -e "  ${G}✓ All packages installed${W}"
}

setup_dirs() {
    echo -e "\n  ${C}${B}[4/7] Setting up directories...${W}"
    
    mkdir -p "$DATA_DIR" "$INDEX_DIR" "$RESULTS_DIR" "$WORK_DIR/logs"
    
    echo -e "  ${G}✓${W} $WORK_DIR/"
    echo -e "    ├── data/      ${DIM}(torrent downloads here)${W}"
    echo -e "    ├── index/     ${DIM}(pre-built index)${W}"
    echo -e "    ├── results/   ${DIM}(extracted email lists)${W}"
    echo -e "    └── logs/      ${DIM}(process logs)${W}"
}

setup_extractor() {
    echo -e "\n  ${C}${B}[5/7] Installing extractor script...${W}"
    
    # Copy extract.py to work dir
    cat > "$WORK_DIR/extract.py" << 'EXTRACTEOF'
#!/usr/bin/env python3
"""
Alien TxtBase — Turbo Email Extractor v2
Multi-core, optimized for 500GB+ datasets.
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
from datetime import datetime

VERSION = "2.0"
DATA_DIR = "./data"
INDEX_DIR = "./index"
RESULTS_DIR = "./results"
CHUNK_SIZE = 64 * 1024 * 1024
EMAIL_RE = re.compile(rb'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}')

G = "\033[92m"; R = "\033[91m"; Y = "\033[93m"; C = "\033[96m"
W = "\033[0m"; B = "\033[1m"; DIM = "\033[2m"; MAG = "\033[95m"


def banner():
    print(f"""{C}{B}
    ╔══════════════════════════════════════════════════╗
    ║   ALIEN TXTBASE — Turbo Extractor v{VERSION}           ║
    ║   Multi-Core • 500GB+ • Zero Duplicates          ║
    ╚══════════════════════════════════════════════════╝{W}
    """)


def fmt_size(b):
    for u in ["B", "KB", "MB", "GB", "TB"]:
        if b < 1024: return f"{b:.1f}{u}"
        b /= 1024
    return f"{b:.1f}PB"


def fmt_num(n):
    if n >= 1_000_000_000: return f"{n/1_000_000_000:.1f}B"
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


def process_chunk(args):
    filepath, start, end, domain_filter = args
    matches = set()
    domain_bytes = domain_filter.encode("utf-8")
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
                if domain_bytes not in line.lower():
                    continue
                email_matches = EMAIL_RE.findall(line)
                for em in email_matches:
                    em_lower = em.lower()
                    if domain_bytes in em_lower:
                        matches.add(em_lower)
    except (OSError, ValueError):
        pass
    return matches, lines_read


def process_chunk_all(args):
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
                email_matches = EMAIL_RE.findall(line)
                for em in email_matches:
                    em_lower = em.lower()
                    try:
                        domain = em_lower.split(b"@")[1].decode("utf-8", errors="ignore")
                        if domain not in domain_map:
                            domain_map[domain] = set()
                        domain_map[domain].add(em_lower)
                    except (ValueError, UnicodeDecodeError):
                        pass
    except (OSError, ValueError):
        pass
    return {d: list(emails) for d, emails in domain_map.items()}, lines_read


def get_file_chunks(filepath, filesize, num_chunks):
    chunk_sz = max(filesize // num_chunks, 1024 * 1024)
    chunks = []
    for i in range(0, filesize, chunk_sz):
        end = min(i + chunk_sz, filesize)
        chunks.append((filepath, i, end))
    return chunks


def extract_domain(files, domain_filter, max_emails, num_workers):
    domain_filter = domain_filter.lower().strip()
    domain_filter = re.sub(r'^https?://', '', domain_filter)
    domain_filter = domain_filter.split("/")[0].strip(".")

    all_emails = set()
    total_lines = 0
    start_time = time.time()

    print(f"\n  {C}Target:{W}     {B}{domain_filter}{W}")
    print(f"  {C}Max:{W}        {B}{fmt_num(max_emails)}{W} emails")
    print(f"  {C}Workers:{W}    {B}{num_workers}{W} CPU cores")
    print(f"  {C}Files:{W}      {B}{len(files)}{W}")
    print(f"  {'─' * 55}")

    for file_idx, (filepath, filesize) in enumerate(files):
        if len(all_emails) >= max_emails:
            break
        fname = os.path.basename(filepath)
        file_start = time.time()
        print(f"\n  {DIM}[{file_idx+1}/{len(files)}] {fname} ({fmt_size(filesize)}){W}")

        chunks = get_file_chunks(filepath, filesize, num_workers * 2)
        chunk_args = [(fp, s, e, domain_filter) for fp, s, e in chunks]
        file_emails = set()
        file_lines = 0

        with Pool(num_workers) as pool:
            for i, (matches, lines) in enumerate(pool.imap_unordered(process_chunk, chunk_args)):
                file_emails.update(matches)
                file_lines += lines
                pct = ((i + 1) / len(chunks)) * 100
                elapsed = time.time() - file_start
                speed = file_lines / elapsed if elapsed > 0 else 0
                print(f"\r    {C}Progress:{W} {pct:5.1f}% | {fmt_num(file_lines)} lines ({fmt_num(speed)}/s) | {G}{len(file_emails)}{W} matches   ", end="", flush=True)
                if len(all_emails) + len(file_emails) >= max_emails:
                    pool.terminate()
                    break

        total_lines += file_lines
        new_unique = len(file_emails - all_emails)
        all_emails.update(file_emails)
        elapsed = time.time() - file_start
        print(f"\r    {G}✓{W} {fmt_num(file_lines)} lines in {fmt_time(elapsed)} | {G}+{new_unique}{W} new emails (total: {B}{len(all_emails)}{W})          ")

        if len(all_emails) >= max_emails:
            print(f"\n  {Y}Limit reached ({max_emails}){W}")
            break

    total_time = time.time() - start_time
    decoded = set()
    for em in all_emails:
        try:
            decoded.add(em.decode("utf-8") if isinstance(em, bytes) else em)
        except (UnicodeDecodeError, AttributeError):
            pass
        if len(decoded) >= max_emails:
            break
    return decoded, total_lines, total_time


def build_index(files, num_workers):
    os.makedirs(INDEX_DIR, exist_ok=True)
    total_lines = 0
    domain_master = {}
    start_time = time.time()

    print(f"\n  {MAG}{B}INDEXING MODE{W} — Processing entire base")
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
            for i, (domain_map, lines) in enumerate(pool.imap_unordered(process_chunk_all, chunk_args)):
                file_lines += lines
                for domain, emails in domain_map.items():
                    if domain not in domain_master:
                        domain_master[domain] = set()
                    for em in emails:
                        domain_master[domain].add(em if isinstance(em, str) else em.decode("utf-8", errors="ignore"))
                pct = ((i + 1) / len(chunks)) * 100
                elapsed = time.time() - file_start
                speed = file_lines / elapsed if elapsed > 0 else 0
                print(f"\r    {C}Progress:{W} {pct:5.1f}% | {fmt_num(file_lines)} lines ({fmt_num(speed)}/s) | {MAG}{len(domain_master)}{W} domains   ", end="", flush=True)

        total_lines += file_lines
        elapsed = time.time() - file_start
        print(f"\r    {G}✓{W} {fmt_num(file_lines)} lines in {fmt_time(elapsed)} | {MAG}{len(domain_master)}{W} domains total          ")

    print(f"\n  {C}Saving index...{W}")
    summary = {}
    for domain, emails in sorted(domain_master.items(), key=lambda x: -len(x[1])):
        summary[domain] = len(emails)
        domain_file = os.path.join(INDEX_DIR, domain.replace(".", "_") + ".txt")
        with open(domain_file, "w") as f:
            for em in sorted(emails):
                f.write(em + "\n")

    with open(os.path.join(INDEX_DIR, "_summary.json"), "w") as f:
        json.dump({
            "created": datetime.now().isoformat(),
            "total_lines": total_lines,
            "total_domains": len(summary),
            "total_emails": sum(summary.values()),
            "time_seconds": time.time() - start_time,
            "domains": summary
        }, f, indent=2)

    total_time = time.time() - start_time
    total_emails = sum(summary.values())

    print(f"\n  {'═' * 55}")
    print(f"  {B}INDEX COMPLETE{W}")
    print(f"  {C}Lignes:{W}     {total_lines:,}")
    print(f"  {G}Emails:{W}     {total_emails:,}")
    print(f"  {MAG}Domaines:{W}   {len(summary):,}")
    print(f"  {C}Temps:{W}      {fmt_time(total_time)}")
    print(f"\n  {G}Top 20 domaines:{W}")
    for i, (dom, count) in enumerate(sorted(summary.items(), key=lambda x: -x[1])[:20]):
        print(f"    {DIM}{i+1:>3}.{W} {dom:<40} {G}{count:>10,}{W}")
    return summary


def query_index(domain_filter, max_emails):
    summary_path = os.path.join(INDEX_DIR, "_summary.json")
    if not os.path.exists(summary_path):
        return None

    domain_filter = domain_filter.lower().strip()
    domain_filter = re.sub(r'^https?://', '', domain_filter)
    domain_filter = domain_filter.split("/")[0].strip(".")

    with open(summary_path) as f:
        summary = json.load(f)

    matching_domains = []
    for dom, count in summary["domains"].items():
        if domain_filter in dom:
            matching_domains.append((dom, count))

    if not matching_domains:
        return set()

    matching_domains.sort(key=lambda x: -x[1])
    print(f"\n  {G}Domaines matchés:{W}")
    for dom, count in matching_domains[:10]:
        print(f"    {DIM}•{W} {dom} — {G}{count:,}{W} emails")

    emails = set()
    for dom, count in matching_domains:
        domain_file = os.path.join(INDEX_DIR, dom.replace(".", "_") + ".txt")
        if os.path.exists(domain_file):
            with open(domain_file) as f:
                for line in f:
                    emails.add(line.strip())
                    if len(emails) >= max_emails:
                        break
        if len(emails) >= max_emails:
            break
    return emails


def export_results(emails, domain_filter):
    os.makedirs(RESULTS_DIR, exist_ok=True)
    clean = re.sub(r'[^a-zA-Z0-9]', '_', domain_filter)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    outfile = os.path.join(RESULTS_DIR, f"leads_{clean}_{len(emails)}_{ts}.txt")
    with open(outfile, "w") as f:
        for em in sorted(emails):
            f.write(em + "\n")
    return outfile


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
    print(f"    {C}1.{W} Extraire emails par domaine (scan direct)")
    if has_index:
        print(f"    {C}2.{W} Extraire emails par domaine {G}(via index — INSTANT){W}")
    print(f"    {C}3.{W} Indexer toute la base")
    print(f"    {C}4.{W} Stats de l'index")
    print()

    choice = input(f"  {C}Choix [1-4]:{W} ").strip()

    if choice == "1":
        domain = input(f"  {C}Domaine cible{W} (ex: target.com): ").strip()
        if not domain: sys.exit(1)
        max_str = input(f"  {C}Combien d'emails max ?{W} {DIM}(défaut: all){W}: ").strip()
        max_emails = int(max_str) if max_str.isdigit() else 999_999_999
        emails, total_lines, elapsed = extract_domain(files, domain, max_emails, num_workers)
        if emails:
            outfile = export_results(emails, domain)
            print(f"\n  {'═' * 55}")
            print(f"  {G}Emails uniques:{W}   {len(emails):,}")
            print(f"  {C}Temps:{W}            {fmt_time(elapsed)}")
            print(f"  {G}{B}→ {outfile}{W}\n")
        else:
            print(f"\n  {R}Aucun email trouvé.{W}\n")

    elif choice == "2" and has_index:
        domain = input(f"  {C}Domaine cible{W}: ").strip()
        if not domain: sys.exit(1)
        max_str = input(f"  {C}Max emails ?{W} {DIM}(défaut: all){W}: ").strip()
        max_emails = int(max_str) if max_str.isdigit() else 999_999_999
        start = time.time()
        emails = query_index(domain, max_emails)
        elapsed = time.time() - start
        if emails:
            outfile = export_results(emails, domain)
            print(f"\n  {G}{B}✓ {len(emails):,} emails en {elapsed:.2f}s → {outfile}{W}\n")
        else:
            print(f"\n  {R}Aucun email.{W}\n")

    elif choice == "3":
        confirm = input(f"\n  {Y}Indexer {fmt_size(total_size)} ? (o/n):{W} ").strip().lower()
        if confirm in ("o", "oui", "y", "yes"):
            build_index(files, num_workers)

    elif choice == "4":
        summary_path = os.path.join(INDEX_DIR, "_summary.json")
        if os.path.exists(summary_path):
            with open(summary_path) as f:
                s = json.load(f)
            print(f"\n  {B}INDEX STATS{W}")
            print(f"  {C}Créé:{W}      {s['created']}")
            print(f"  {G}Emails:{W}    {s['total_emails']:,}")
            print(f"  {MAG}Domaines:{W}  {s['total_domains']:,}")
            print(f"\n  {G}Top 30:{W}")
            for i, (dom, count) in enumerate(sorted(s['domains'].items(), key=lambda x: -x[1])[:30]):
                print(f"    {DIM}{i+1:>3}.{W} {dom:<35} {G}{count:>10,}{W}")
        else:
            print(f"  {R}Pas d'index.{W}")


def main():
    parser = argparse.ArgumentParser(description="Alien TxtBase Email Extractor v2")
    parser.add_argument("-d", "--domain", help="Domain to filter")
    parser.add_argument("-n", "--max", type=int, default=999999999, help="Max emails")
    parser.add_argument("-w", "--workers", type=int, default=0, help="CPU workers (0=auto)")
    parser.add_argument("--index", action="store_true", help="Build full index")
    parser.add_argument("--query", action="store_true", help="Query existing index")
    args = parser.parse_args()

    if not args.domain and not args.index and not args.query:
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
    elif args.query and args.domain:
        emails = query_index(args.domain, args.max)
        if emails:
            outfile = export_results(emails, args.domain)
            print(f"  {G}✓ {len(emails):,} emails → {outfile}{W}")
    elif args.domain:
        emails, lines, elapsed = extract_domain(files, args.domain, args.max, num_workers)
        if emails:
            outfile = export_results(emails, args.domain)
            print(f"\n  {G}✓ {len(emails):,} emails in {fmt_time(elapsed)} → {outfile}{W}")


if __name__ == "__main__":
    main()
EXTRACTEOF

    chmod +x "$WORK_DIR/extract.py"
    echo -e "  ${G}✓ extract.py installed${W}"
}

setup_qbittorrent() {
    echo -e "\n  ${C}${B}[6/7] Configuring qBittorrent...${W}"
    
    # Create systemd service
    cat > /etc/systemd/system/qbittorrent.service << EOF
[Unit]
Description=qBittorrent-nox Daemon
After=network.target

[Service]
Type=forking
User=root
ExecStart=/usr/bin/qbittorrent-nox -d --webui-port=$QB_PORT
Restart=on-failure
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

    # qBittorrent config — optimized for max speed
    mkdir -p /root/.config/qBittorrent
    cat > /root/.config/qBittorrent/qBittorrent.conf << EOF
[LegalNotice]
Accepted=true

[Preferences]
WebUI\Port=$QB_PORT
WebUI\Username=$QB_USER
WebUI\Password_PBKDF2="@ByteArray(ARQ77eY1NUZaQsuDHbIMCA==:0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8NR1Gdeuj7y/8I=)"
Downloads\SavePath=$DATA_DIR
Connection\PortRangeMin=6881
Connection\GlobalDLLimitAlt=0
Connection\GlobalUPLimitAlt=0
Connection\MaxConnections=-1
Connection\MaxConnectionsPerTorrent=-1
Connection\MaxUploadsPerTorrent=-1
Bittorrent\MaxRatio=0
Bittorrent\MaxRatioAction=1
Downloads\TempPath=$DATA_DIR/temp
Downloads\TempPathEnabled=true
General\Locale=en
EOF

    systemctl daemon-reload
    systemctl enable qbittorrent --quiet
    systemctl start qbittorrent
    
    sleep 2
    echo -e "  ${G}✓ qBittorrent running on port $QB_PORT${W}"
}

setup_monitoring() {
    echo -e "\n  ${C}${B}[7/7] Setting up monitoring...${W}"
    
    # Download progress monitor script
    cat > "$WORK_DIR/monitor.sh" << 'MONEOF'
#!/bin/bash
C="\033[96m"; G="\033[92m"; Y="\033[93m"; W="\033[0m"; B="\033[1m"
DATA_DIR="/root/alien/data"

while true; do
    clear
    echo -e "${C}${B}"
    echo "    ╔═══════════════════════════════════════════╗"
    echo "    ║   ALIEN TXTBASE — Download Monitor        ║"
    echo "    ╚═══════════════════════════════════════════╝"
    echo -e "${W}"
    
    # Disk usage
    USED=$(du -sh "$DATA_DIR" 2>/dev/null | awk '{print $1}')
    AVAIL=$(df -h "$DATA_DIR" | tail -1 | awk '{print $4}')
    echo -e "  ${C}Downloaded:${W}  ${B}${USED}${W} / 562GB"
    echo -e "  ${C}Disk free:${W}   ${AVAIL}"
    
    # File count
    TXT_COUNT=$(find "$DATA_DIR" -name "*.txt" -type f 2>/dev/null | wc -l)
    RAR_COUNT=$(find "$DATA_DIR" -name "*.rar" -type f 2>/dev/null | wc -l)
    echo -e "  ${C}Files:${W}       ${G}${TXT_COUNT} .txt${W} | ${Y}${RAR_COUNT} .rar${W}"
    
    # RAM & CPU
    echo ""
    echo -e "  ${C}RAM:${W}  $(free -h | awk '/Mem:/{printf "%s / %s", $3, $2}')"
    echo -e "  ${C}CPU:${W}  $(uptime | awk -F'load average:' '{print $2}' | xargs)"
    echo -e "  ${C}I/O:${W}  $(iostat -d 2>/dev/null | head -4 | tail -1 || echo 'install sysstat')"
    
    echo -e "\n  ${C}Press Ctrl+C to exit${W}"
    sleep 10
done
MONEOF
    chmod +x "$WORK_DIR/monitor.sh"

    # Auto-extract watcher — extracts .rar as they download
    cat > "$WORK_DIR/auto_extract.sh" << 'AUTOEOF'
#!/bin/bash
G="\033[92m"; Y="\033[93m"; C="\033[96m"; W="\033[0m"; B="\033[1m"
DATA_DIR="/root/alien/data"
EXTRACTED_LOG="/root/alien/logs/extracted.log"
touch "$EXTRACTED_LOG"

echo -e "${C}${B}Auto-Extract Watcher${W} — monitoring $DATA_DIR"
echo -e "${C}Extracts .rar files as they complete downloading${W}\n"

while true; do
    for rar in $(find "$DATA_DIR" -name "*.rar" -type f 2>/dev/null); do
        if ! grep -q "$rar" "$EXTRACTED_LOG" 2>/dev/null; then
            # Check if file is still being written (size changing)
            SIZE1=$(stat -c%s "$rar" 2>/dev/null)
            sleep 5
            SIZE2=$(stat -c%s "$rar" 2>/dev/null)
            
            if [ "$SIZE1" = "$SIZE2" ] && [ -n "$SIZE1" ]; then
                echo -e "  ${Y}Extracting:${W} $(basename $rar)"
                unrar x -o+ "$rar" "$DATA_DIR/" > /dev/null 2>&1
                if [ $? -eq 0 ]; then
                    echo "$rar" >> "$EXTRACTED_LOG"
                    echo -e "  ${G}✓ Done:${W} $(basename $rar)"
                    # Optional: delete .rar after extraction to save space
                    # rm -f "$rar"
                fi
            fi
        fi
    done
    sleep 30
done
AUTOEOF
    chmod +x "$WORK_DIR/auto_extract.sh"
    
    echo -e "  ${G}✓ Monitor & auto-extract scripts ready${W}"
}

print_summary() {
    IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    echo -e "\n${C}${B}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║              SETUP COMPLETE                          ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${W}"
    
    echo -e "  ${B}qBittorrent Web UI:${W}"
    echo -e "    ${C}URL:${W}       http://${IP}:${QB_PORT}"
    echo -e "    ${C}User:${W}      ${QB_USER}"
    echo -e "    ${C}Pass:${W}      ${QB_PASS}"
    
    echo -e "\n  ${B}Directories:${W}"
    echo -e "    ${C}Data:${W}      ${DATA_DIR}"
    echo -e "    ${C}Index:${W}     ${INDEX_DIR}"
    echo -e "    ${C}Results:${W}   ${RESULTS_DIR}"
    
    echo -e "\n  ${B}━━━ STEP BY STEP ━━━${W}"
    echo -e ""
    echo -e "  ${G}1.${W} Open qBittorrent: ${C}http://${IP}:${QB_PORT}${W}"
    echo -e "  ${G}2.${W} Add magnet link (it's pre-copied below)"
    echo -e "  ${G}3.${W} Monitor download: ${C}./monitor.sh${W}"
    echo -e "  ${G}4.${W} Auto-extract .rar: ${C}screen -S extract ./auto_extract.sh${W}"
    echo -e "  ${G}5.${W} Index the base:    ${C}python3 extract.py --index${W}"
    echo -e "  ${G}6.${W} Query any domain:  ${C}python3 extract.py --query -d target.com${W}"
    
    echo -e "\n  ${B}Magnet link:${W}"
    echo -e "  ${DIM}${MAGNET}${W}"
    
    echo -e "\n  ${B}Quick commands:${W}"
    echo -e "    ${C}cd $WORK_DIR${W}"
    echo -e "    ${C}python3 extract.py${W}                        ${DIM}# Interactive menu${W}"
    echo -e "    ${C}python3 extract.py -d target.com${W}          ${DIM}# Direct extract${W}"
    echo -e "    ${C}python3 extract.py -d .ch -n 50000${W}        ${DIM}# All Swiss emails${W}"
    echo -e "    ${C}python3 extract.py --index${W}                ${DIM}# Full indexation${W}"
    echo -e "    ${C}python3 extract.py --query -d gmail.com${W}   ${DIM}# Instant query${W}"
    echo -e "    ${C}./monitor.sh${W}                              ${DIM}# Download progress${W}"
    echo ""
}

# ═══════════════════════════════════════════════════════
#  RUN
# ═══════════════════════════════════════════════════════

banner
check_root
check_disk
check_ram
install_deps
setup_dirs
setup_extractor
setup_qbittorrent
setup_monitoring
print_summary
