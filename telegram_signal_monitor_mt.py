#!/usr/bin/env python3
import asyncio
import ast
import configparser
import json
import os
import re
import sqlite3
import sys
from datetime import datetime

from dotenv import load_dotenv
from telethon import TelegramClient, events

load_dotenv()

API_ID = os.getenv("TELEGRAM_API_ID")
API_HASH = os.getenv("TELEGRAM_API_HASH")
PHONE_NUMBER = os.getenv("TELEGRAM_PHONE_NUMBER", "+1234567890")

DB_PATH = os.getenv("DATABASE_PATH", "telegram_signals.db")

CHAT_CONFIG = None
CHANNEL_USERNAME = None
CHANNEL_ID = None
CHAT_ENTITY = None
SIGNAL_PATTERNS = None
DB_SOURCE = None
BROKER = None
SYMBOL_POSTFIX = ""
TRADING_PLATFORM = "MT5"
TERMINAL_INPUT_FOLDER = None
TERMINAL_OUTPUT_FOLDER = None
DEFAULT_VOLUME = 0.1
DIRECTION_GROUP = 1
SYMBOL_GROUP = 2
PRICE_GROUP = 3
SL_GROUP_INDEXES = [4]
TP_GROUP_INDEXES = [5]
SYMBOL_MAPPING = {}

def read_config_section(config_file):
    """Read flat key/value config files or standard INI files."""
    with open(config_file, "r", encoding="utf-8") as handle:
        raw_text = handle.read()

    if re.search(r"^\s*\[", raw_text, re.MULTILINE):
        parser = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=("#", ";"))
        parser.optionxform = str
        parser.read_string(raw_text)
        return dict(parser["DEFAULT"])

    section = {}
    lines = raw_text.splitlines()
    i = 0

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        i += 1

        if not stripped or stripped.startswith("#") or stripped.startswith(";"):
            continue

        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()

        if value and value[0] in ("'", '"') and not value.endswith(value[0]):
            quote = value[0]
            value_lines = [value]
            while i < len(lines):
                continuation = lines[i]
                value_lines.append(continuation)
                i += 1
                if continuation.rstrip().endswith(quote):
                    break
            value = "\n".join(value_lines)
        elif value and value[0] not in ("'", '"'):
            value = re.split(r"\s(?=[#;])", value, 1)[0].strip()

        section[key] = value

    return section


def parse_signal_patterns(raw_patterns):
    """Parse SIGNAL_PATTERNS from JSON or Python-literal text."""
    if not raw_patterns:
        return {}

    text = raw_patterns.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("'", '"'):
        text = text[1:-1]

    for parser in (json.loads, ast.literal_eval):
        try:
            parsed = parser(text)
            if isinstance(parsed, dict):
                return parsed
        except Exception:
            pass

    normalized = re.sub(r"(?<!\\)\\(?![\\\"/bfnrtu])", r"\\\\", text)
    parsed = json.loads(normalized)
    if not isinstance(parsed, dict):
        raise ValueError("SIGNAL_PATTERNS must resolve to a dictionary.")
    return parsed


def parse_symbol_mapping(raw_mapping):
    """Parse SYMBOL_MAPPING from JSON or Python-literal text."""
    if not raw_mapping:
        return {}

    text = raw_mapping.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("'", '"'):
        text = text[1:-1]

    for parser in (json.loads, ast.literal_eval):
        try:
            parsed = parser(text)
            if isinstance(parsed, dict):
                return parsed
        except Exception:
            pass

    normalized = re.sub(r"(?<!\\)\\(?![\\\"/bfnrtu])", r"\\\\", text)
    parsed = json.loads(normalized)
    if not isinstance(parsed, dict):
        raise ValueError("SYMBOL_MAPPING must resolve to a dictionary.")
    return parsed

def _parse_group_indexes(raw, default):
    """Parse a comma-separated list of regex group indexes from a config string."""
    if not raw:
        return default
    indexes = []
    for part in raw.split(","):
        part = part.strip()
        if part:
            try:
                indexes.append(int(part))
            except ValueError:
                pass
    return indexes if indexes else default

def load_chat_config(config_file):
    """Load chat-specific configuration from INI file."""
    global CHANNEL_USERNAME, CHANNEL_ID, SIGNAL_PATTERNS, DB_SOURCE, CHAT_CONFIG
    global BROKER, SYMBOL_POSTFIX, TRADING_PLATFORM
    global TERMINAL_INPUT_FOLDER, TERMINAL_OUTPUT_FOLDER, DEFAULT_VOLUME
    global DIRECTION_GROUP, SYMBOL_GROUP, PRICE_GROUP
    global SL_GROUP_INDEXES, TP_GROUP_INDEXES, SYMBOL_MAPPING

    if not os.path.exists(config_file):
        print(f"Error: Chat config file '{config_file}' not found.")
        sys.exit(1)

    try:
        section = read_config_section(config_file)

        CHANNEL_USERNAME = (section.get("CHAT_USERNAME") or section.get("CHANNEL_NAME") or "").strip()
        CHANNEL_ID = (section.get("CHAT_ID") or "").strip()
        DB_SOURCE = section.get("DB_SOURCE", "Unknown")
        BROKER = section.get("BROKER", "Unknown")
        SYMBOL_POSTFIX = section.get("SYMBOL_POSTFIX", "")
        DEFAULT_VOLUME = float(section.get("DEFAULT_VOLUME", 0.1))

        platform_from_config = (
            section.get("MARKET_TYPE")
            or section.get("MT_TYPE")
            or section.get("PLATFORM")
            or "MT5"
        )
        normalized_platform = str(platform_from_config).strip().upper()
        if normalized_platform in {"MT4", "MQL4", "4"}:
            TRADING_PLATFORM = "MT4"
            mql_folder = "MQL4"
        elif normalized_platform in {"MT5", "MQL5", "5"}:
            TRADING_PLATFORM = "MT5"
            mql_folder = "MQL5"
        else:
            raise ValueError(
                f"Invalid market type '{platform_from_config}'. Use MT4 or MT5."
            )

        if not CHANNEL_USERNAME and not CHANNEL_ID:
            raise ValueError("CHAT_USERNAME/CHANNEL_NAME or CHAT_ID is required.")

        patterns_str = section.get("SIGNAL_PATTERNS", "{}")
        SIGNAL_PATTERNS = parse_signal_patterns(patterns_str)

        symbol_mapping_str = section.get("SYMBOL_MAPPING", "{}")
        SYMBOL_MAPPING = parse_symbol_mapping(symbol_mapping_str)

        DIRECTION_GROUP = int(section.get("DIRECTION_GROUP", 1))
        SYMBOL_GROUP = int(section.get("SYMBOL_GROUP", 2))
        PRICE_GROUP = int(section.get("PRICE_GROUP", 3))
        SL_GROUP_INDEXES = _parse_group_indexes(section.get("SL_GROUP"), [4])
        TP_GROUP_INDEXES = _parse_group_indexes(section.get("TP_GROUP"), [6])

        base_terminal_path = os.getenv(
            "MT_BASE_PATH",
            r"C:\\Users\\YourUsername\\AppData\\Roaming\\MetaQuotes\\Terminal",
        )
        TERMINAL_INPUT_FOLDER = f"{base_terminal_path}\\{BROKER}\\{mql_folder}\\Files\\input"
        TERMINAL_OUTPUT_FOLDER = f"{base_terminal_path}\\{BROKER}\\{mql_folder}\\Files\\output"

        CHAT_CONFIG = config_file
        print(f"Loaded chat configuration from: {config_file}")
        print(f"Monitoring chat username: {CHANNEL_USERNAME or 'N/A'}")
        print(f"Monitoring chat ID: {CHANNEL_ID or 'N/A'}")
        print(f"Database source: {DB_SOURCE}")
        print(f"Broker: {BROKER}")
        print(f"Trading platform: {TRADING_PLATFORM}")
        print(f"Symbol postfix: {SYMBOL_POSTFIX}")
        print(f"Default volume: {DEFAULT_VOLUME}")
        print(f"Direction group: {DIRECTION_GROUP}")
        print(f"Symbol group: {SYMBOL_GROUP}")
        print(f"Price group: {PRICE_GROUP}")
        print(f"SL group indexes: {SL_GROUP_INDEXES}")
        print(f"TP group indexes: {TP_GROUP_INDEXES}")
        print(f"Symbol mapping entries: {len(SYMBOL_MAPPING)}")
        print(f"Terminal input folder: {TERMINAL_INPUT_FOLDER}")
        print(f"Terminal output folder: {TERMINAL_OUTPUT_FOLDER}")
    except Exception as exc:
        print(f"Error loading chat config: {exc}")
        sys.exit(1)


def normalize_signal_symbol(symbol):
    """Normalize a signal symbol to a key-safe uppercase format."""
    return re.sub(r"[^A-Za-z0-9._-]", "", (symbol or "").strip()).upper()


def sync_symbol_mappings_to_db():
    """Insert configured symbol mappings into DB if missing."""
    if not SYMBOL_MAPPING:
        return

    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()

    inserted = 0
    for signal_symbol, mapped_symbol in SYMBOL_MAPPING.items():
        signal_key = normalize_signal_symbol(str(signal_symbol))
        mapped_value = str(mapped_symbol).strip()
        if not signal_key or not mapped_value:
            continue

        c.execute(
            """
            INSERT OR IGNORE INTO symbol_mappings (source, signal_symbol, mapped_symbol)
            VALUES (?, ?, ?)
            """,
            (DB_SOURCE, signal_key, mapped_value),
        )
        if c.rowcount > 0:
            inserted += 1

    conn.commit()
    conn.close()

    if inserted:
        print(f"Inserted {inserted} new symbol mapping(s) for source '{DB_SOURCE}'")


def get_mapped_symbol(signal_symbol):
    """Get mapped broker symbol for a normalized signal symbol from DB."""
    signal_key = normalize_signal_symbol(signal_symbol)
    if not signal_key:
        return None

    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute(
        """
        SELECT mapped_symbol
        FROM symbol_mappings
        WHERE source = ? AND signal_symbol = ?
        LIMIT 1
        """,
        (DB_SOURCE, signal_key),
    )
    row = c.fetchone()
    conn.close()

    if row and row[0]:
        return str(row[0]).strip()
    return None


def init_db():
    """Initialize the database with required tables."""
    from init_database import init_db as _init_db

    _init_db()


def save_message_to_db(msg_id, message_text, action=None, full_message=None):
    """Save a processed message to the database."""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute(
        "INSERT OR REPLACE INTO messages (msg_id, message_text, timestamp, action, source, full_message) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (msg_id, message_text, datetime.now(), action, DB_SOURCE, full_message),
    )
    conn.commit()
    conn.close()


def parse_message_ids(input_str):
    """Parse comma/space separated message IDs and ranges."""
    message_ids = set()

    for part in re.split(r"[,\s]+", input_str.strip()):
        part = part.strip()
        if not part:
            continue

        if "-" in part:
            try:
                start, end = map(int, part.split("-", 1))
                message_ids.update(range(start, end + 1))
            except ValueError:
                print(f"Invalid range format: {part}")
        else:
            try:
                message_ids.add(int(part))
            except ValueError:
                print(f"Invalid message ID: {part}")

    return sorted(message_ids)


def sanitize_message_text(message_text):
    """Remove common markdown markers that can break regex parsing."""
    if not message_text:
        return ""
    return re.sub(r"[`*]+", "", message_text)


def resolve_symbol(signal_symbol):
    """Resolve symbol by DB mapping first, else fallback to UPPERCASE+postfix."""
    mapped_symbol = get_mapped_symbol(signal_symbol)
    if mapped_symbol:
        return mapped_symbol

    fallback_symbol = normalize_signal_symbol(signal_symbol)
    if SYMBOL_POSTFIX and not fallback_symbol.endswith(SYMBOL_POSTFIX):
        return f"{fallback_symbol}{SYMBOL_POSTFIX}"
    return fallback_symbol


def _pick_group(match, indexes):
    """Return the first non-empty group value matching any of the given indexes (OR semantics).
    Whitespace is stripped from the returned value."""
    for idx in indexes:
        if match.lastindex and match.lastindex >= idx:
            val = match.group(idx)
            if val:
                return re.sub(r"\s+", "", val)
    return None


def parse_signal_message(message_text):
    """Parse CREATE market/pending signals from configured regex patterns."""
    default_patterns = {
        "create_market": r"(BUY|SELL)\s+([A-Z0-9._/-]+)(?:\s+@?\s*([\d.]+))?\s+SL[:\s]+([\d.]+)\s+TP[:\s]+([\d.]+)",
    }

    configured_patterns = SIGNAL_PATTERNS or {}
    patterns = [configured_patterns.get("create_market", default_patterns["create_market"])]

    pending_pattern = configured_patterns.get("create_pending")
    if pending_pattern:
        patterns.append(pending_pattern)

    for pattern in patterns:
        match = re.search(pattern, message_text, re.IGNORECASE)
        if not match:
            continue

        # Extract using configured group indexes
        raw_side = re.sub(r"\s+", " ", (match.group(DIRECTION_GROUP) or "").strip()).upper()
        raw_symbol = match.group(SYMBOL_GROUP)
        raw_price_str = re.sub(r"\s+", "", (match.group(PRICE_GROUP) or ""))

        side = raw_side.split(" ", 1)[0]
        order_type = "MARKET"
        price = 0.0

        if "STOP" in raw_side or "LIMIT" in raw_side:
            order_type = raw_side.replace(" ", "")
            price = float(raw_price_str) if raw_price_str else 0.0

        raw_sl = _pick_group(match, SL_GROUP_INDEXES)
        raw_tp = _pick_group(match, TP_GROUP_INDEXES)
        sl = float(raw_sl) if raw_sl else 0.0
        tp = float(raw_tp) if raw_tp else 0.0

        return {
            "action": "CREATE",
            "symbol": resolve_symbol(raw_symbol),
            "type": order_type,
            "side": side,
            "volume": DEFAULT_VOLUME,
            "price": price,
            "sl": sl,
            "tp": tp,
            "broker": BROKER,
        }

    return None


def generate_json_file(order_data, msg_id):
    """Generate JSON file for terminal processing."""
    if not os.path.exists(TERMINAL_INPUT_FOLDER):
        os.makedirs(TERMINAL_INPUT_FOLDER)

    file_path = os.path.join(TERMINAL_INPUT_FOLDER, f"{msg_id}.json")
    with open(file_path, "w", encoding="utf-8") as handle:
        json.dump(order_data, handle, indent=2)

    print(f"Generated JSON file: {file_path}")


async def resolve_chat_entity(client):
    """Resolve a chat target from CHAT_ID or CHANNEL_USERNAME."""
    candidates = []

    if CHANNEL_ID:
        chat_id_text = CHANNEL_ID.strip()
        if re.fullmatch(r"-?\d+", chat_id_text):
            numeric_id = int(chat_id_text)
            candidates.append(numeric_id)
            if numeric_id > 0:
                candidates.append(int(f"-100{numeric_id}"))
        else:
            candidates.append(chat_id_text)

    if CHANNEL_USERNAME:
        candidates.append(CHANNEL_USERNAME)

    errors = []
    for candidate in candidates:
        try:
            entity = await client.get_entity(candidate)
            print(f"Resolved chat target using: {candidate}")
            return entity
        except Exception as exc:
            errors.append(f"{candidate}: {exc}")

    raise ValueError("Unable to resolve chat from CHAT_ID/CHAT_USERNAME. " + " | ".join(errors))


async def process_message(client, msg_id):
    """Fetch and process a specific message ID."""
    try:
        target = CHAT_ENTITY or CHANNEL_USERNAME
        message = await client.get_messages(target, ids=msg_id)
        if not message:
            print(f"Message {msg_id} not found")
            return

        cleaned_text = sanitize_message_text(message.text or "")

        print(f"\nProcessing message ID: {msg_id}")
        print(f"Message text: {cleaned_text}")

        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("SELECT processed FROM messages WHERE msg_id = ?", (str(msg_id),))
        result = c.fetchone()
        conn.close()

        if result and result[0]:
            print(f"Message {msg_id} already processed, skipping.")
            return

        order_data = parse_signal_message(cleaned_text)
        if not order_data:
            print(f"Message {msg_id} ignored - not a direct BUY/SELL open signal")
            return

        order_data["msg_id"] = str(msg_id)
        generate_json_file(order_data, str(msg_id))
        save_message_to_db(str(msg_id), cleaned_text, order_data["action"], cleaned_text)
        print(f"Successfully processed signal: {order_data}")
    except Exception as exc:
        print(f"Error processing message {msg_id}: {exc}")


async def fetch_and_process_messages(client, message_ids):
    """Fetch and process specific messages by ID for testing."""
    print(f"Fetching {len(message_ids)} messages for testing...")
    for msg_id in message_ids:
        await process_message(client, msg_id)


async def main():
    """Main function to monitor Telegram channel or test specific messages."""
    global CHAT_ENTITY

    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 telegram_signal_monitor.py <chat_config.ini> [message_ids]")
        print("Examples:")
        print("  python3 telegram_signal_monitor.py forex_signals.ini")
        print('  python3 telegram_signal_monitor.py forex_signals.ini "123,456"')
        sys.exit(1)

    chat_config_file = sys.argv[1]
    load_chat_config(chat_config_file)
    init_db()
    sync_symbol_mappings_to_db()

    if len(sys.argv) > 2:
        message_ids = parse_message_ids(sys.argv[2])
        if not message_ids:
            print("No valid message IDs provided. Use format like '123,456' or '100-150'")
            return

        print(f"Test mode: Processing message IDs: {message_ids}")
        client = TelegramClient(f"session_{DB_SOURCE}", API_ID, API_HASH)
        await client.start(PHONE_NUMBER)
        try:
            CHAT_ENTITY = await resolve_chat_entity(client)
            await fetch_and_process_messages(client, message_ids)
        finally:
            await client.disconnect()
        return

    client = TelegramClient(f"session_{DB_SOURCE}", API_ID, API_HASH)
    await client.start(PHONE_NUMBER)
    CHAT_ENTITY = await resolve_chat_entity(client)

    @client.on(events.NewMessage(chats=CHAT_ENTITY))
    async def handler(event):
        msg_id = str(event.message.id)
        cleaned_text = sanitize_message_text(event.message.text or "")
        print(f"New message received: {msg_id}")

        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("SELECT processed FROM messages WHERE msg_id = ?", (msg_id,))
        result = c.fetchone()
        conn.close()

        if result and result[0]:
            print(f"Message {msg_id} already processed, skipping.")
            return

        order_data = parse_signal_message(cleaned_text)
        if not order_data:
            print(f"Message {msg_id} ignored - not a direct BUY/SELL open signal")
            return

        order_data["msg_id"] = msg_id
        generate_json_file(order_data, msg_id)
        save_message_to_db(msg_id, cleaned_text, order_data["action"], cleaned_text)
        print(f"Processed signal: {order_data}")

    print(f"Monitoring Telegram channel: {CHANNEL_USERNAME or CHANNEL_ID}")
    print(f"Database source: {DB_SOURCE}")
    await client.run_until_disconnected()


if __name__ == "__main__":
    asyncio.run(main())
