#!/usr/bin/env python3
import configparser
import os
import re
import sqlite3
import time
import sys

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

# Database path from .env
DB_PATH = os.getenv('DATABASE_PATH', 'telegram_signals.db')

# MT terminal base path from .env
MT_BASE_PATH = os.getenv('MT_BASE_PATH', r'C:\Users\YourUsername\AppData\Roaming\MetaQuotes\Terminal')


def read_config_section(config_file):
    """Read flat key/value config files (no section headers) or standard INI files."""
    with open(config_file, 'r', encoding='utf-8') as handle:
        raw_text = handle.read()

    if re.search(r'^\s*\[', raw_text, re.MULTILINE):
        parser = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=('#', ';'))
        parser.optionxform = str
        parser.read_string(raw_text)
        return dict(parser['DEFAULT'])

    section = {}
    for raw_line in raw_text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith('#') or line.startswith(';'):
            continue
        if '=' not in raw_line:
            continue
        key, value = raw_line.split('=', 1)
        key = key.strip()
        value = value.strip()
        if value and value[0] not in ("'", '"'):
            value = re.split(r'\s(?=[#;])', value, 1)[0].strip()
        section[key] = value
    return section


def resolve_paths_from_ini(ini_file):
    """Parse an ini config and return (platform, broker, db_source, output_folder, archive_folder)."""
    section = read_config_section(ini_file)

    broker = section.get('BROKER', '').strip()
    if not broker:
        raise ValueError(f"BROKER not set in {ini_file}")

    db_source = section.get('DB_SOURCE', '').strip()

    market_type = (
        section.get('MARKET_TYPE') or
        section.get('MT_TYPE') or
        section.get('PLATFORM') or
        'MT5'
    ).strip().upper()

    if market_type in ('MT4', 'MQL4', '4'):
        platform = 'MT4'
        mql_folder = 'MQL4'
    elif market_type in ('MT5', 'MQL5', '5'):
        platform = 'MT5'
        mql_folder = 'MQL5'
    else:
        raise ValueError(f"Invalid MARKET_TYPE '{market_type}' in {ini_file}. Use MT4 or MT5.")

    output_folder = os.path.join(MT_BASE_PATH, broker, mql_folder, 'Files', 'output')
    archive_folder = os.path.join(MT_BASE_PATH, broker, mql_folder, 'Files', 'archive', 'output')

    return platform, broker, db_source, output_folder, archive_folder


def update_db_with_ticket(msg_id, ticket, db_source):
    """Update the database with ticket information for a given msg_id."""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()

    if db_source:
        c.execute(
            'UPDATE messages SET ticket = ?, processed = TRUE WHERE msg_id = ? AND source = ?',
            (ticket, msg_id, db_source),
        )
    else:
        c.execute(
            'UPDATE messages SET ticket = ?, processed = TRUE WHERE msg_id = ?',
            (ticket, msg_id),
        )

    if c.rowcount > 0:
        print(f"  Updated ticket for msg_id {msg_id}: {ticket}")
    else:
        print(f"  No message found with msg_id {msg_id}" + (f" (source={db_source})" if db_source else ""))

    conn.commit()
    conn.close()


def archive_output_file(output_folder, archive_folder, filename):
    """Move a processed output file to the archive folder."""
    source_path = os.path.join(output_folder, filename)
    archive_path = os.path.join(archive_folder, filename)

    os.makedirs(archive_folder, exist_ok=True)

    try:
        os.rename(source_path, archive_path)
        print(f"  Archived: {filename}")
    except OSError as e:
        print(f"  Error archiving {filename}: {e}")


def process_ini(ini_file):
    """Process all pending output files for one ini config."""
    try:
        platform, broker, db_source, output_folder, archive_folder = resolve_paths_from_ini(ini_file)
    except ValueError as e:
        print(f"[SKIP] {ini_file}: {e}")
        return

    ini_name = os.path.basename(ini_file)
    print(f"[{ini_name}] {platform} broker={broker} source={db_source or '(none)'}")

    if not os.path.exists(output_folder):
        print(f"  Output folder not found: {output_folder}")
        return

    txt_files = [f for f in os.listdir(output_folder) if f.endswith('.txt')]
    if not txt_files:
        return

    for filename in txt_files:
        msg_id = filename[:-4]  # strip .txt extension
        file_path = os.path.join(output_folder, filename)
        try:
            with open(file_path, 'r') as f:
                ticket = int(f.read().strip())
            update_db_with_ticket(msg_id, ticket, db_source)
            archive_output_file(output_folder, archive_folder, filename)
        except (ValueError, IOError) as e:
            print(f"  Error processing {filename}: {e}")


def main():
    """Continuously monitor output folders for all supplied ini configs."""
    if len(sys.argv) < 2:
        print("Usage: python trade_response.py <ini_file1> [ini_file2 ...]")
        print("Example: python trade_response.py cedricfx_signal.ini leotrading_signal.ini")
        sys.exit(1)

    ini_files = sys.argv[1:]
    print(f"Starting trade response processor for {len(ini_files)} config(s)")

    while True:
        for ini_file in ini_files:
            try:
                process_ini(ini_file)
            except Exception as e:
                print(f"[ERROR] {ini_file}: {e}")
        time.sleep(10)


if __name__ == '__main__':
    main()