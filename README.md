# Alien The Bot

ULP Database Extractor — Multi-core, optimized for 500GB+ datasets. Zero duplicates.

## Features
- Full ULP extraction (URL:Email:Password)
- Multi-core parallel processing
- Zero duplicates (MD5 hash dedup)
- Domain filtering
- Full base indexing for instant queries
- Auto-extract .rar/.zip/.gz/.7z archives
- Streaming output (no RAM overflow on billions of lines)

## Quick Start

```bash
# Interactive mode
python3 extract.py

# Filter by domain (full URL:Email:Pass combos)
python3 extract.py -d target.com -n 5000

# All .ch domains
python3 extract.py -d .ch -n 50000

# Dedup entire base (no filter)
python3 extract.py --all

# Index then instant queries
python3 extract.py --index
python3 extract.py --query -d target.com
```

## VPS Auto Setup

One-command install: torrent client + extractor + monitoring.

```bash
chmod +x setup_vps.sh && ./setup_vps.sh
```

## Data Sources

Place your ULP files (.txt) in the `./data/` directory. Supported formats:
- `URL:Email:Password` (standard ULP)
- `.rar`, `.zip`, `.gz`, `.7z` archives (auto-extracted)

## Requirements

- Python 3.10+
- No external dependencies (stdlib only)
