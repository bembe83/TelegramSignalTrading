# Copy Trading Bot

This project monitors Telegram channels and converts trading signals into JSON files consumed by MetaTrader Expert Advisors.

The current monitor script is `telegram_signal_monitor_mt.py` and supports both MT4 and MT5 path layouts from the same codebase.

## Current Behavior (telegram_signal_monitor_mt.py)

1. Loads a per-chat config file (flat `KEY=VALUE` or INI format).
2. Resolves market type (`MT4` or `MT5`) and picks the matching folder (`MQL4` or `MQL5`).
3. Resolves the target Telegram chat by `CHAT_ID` and/or `CHAT_USERNAME`.
4. Parses only direct open signals using regex patterns from `SIGNAL_PATTERNS`.
5. Creates one JSON input file per message in terminal `Files/input`.
6. Syncs configured symbol mappings into DB (insert-if-missing).
7. Resolves symbols using DB mapping first, otherwise fallback to `UPPERCASE(signal_symbol)+SYMBOL_POSTFIX`.
8. Stores message metadata in SQLite.

Important: parsed open signals are generated as `action=CREATE` with `type=MARKET` and `side=BUY/SELL`. Price is set to `0.0` in JSON and execution side/price is resolved by the EA at order time.

## Components

1. `telegram_signal_monitor_mt.py`: Main Telegram monitor for MT4/MT5.
2. `mt4_order_manager.mq4`: MT4 EA that processes JSON input files.
3. `mt5_order_manager.mq5`: MT5 EA that processes JSON input files.
4. `update_db_from_mt4.py`: Reads terminal output files and updates the database.
5. `init_database.py`: Initializes database/tables.
6. `chat_config_template.ini`: Template for per-chat configuration.

## Setup

### 1. Install Dependencies

```bash
pip install -r requirements.txt
```

### 2. Environment Variables (.env)

```env
TELEGRAM_API_ID=your_api_id
TELEGRAM_API_HASH=your_api_hash
TELEGRAM_PHONE_NUMBER=+1234567890
DATABASE_PATH=telegram_signals.db
MT_BASE_PATH=C:\Users\YourUsername\AppData\Roaming\MetaQuotes\Terminal
```

Notes:
- `MT_BASE_PATH` is the root containing broker terminal hashes.
- If `MT_BASE_PATH` is not set, the script falls back to `C:\Users\YourUsername\AppData\Roaming\MetaQuotes\Terminal`.

### 3. Initialize Database

```bash
python init_database.py
```

## Usage

### Normal Monitor Mode

```bash
python telegram_signal_monitor_mt.py my_channel.ini
```

### Test Mode (specific message IDs)

```bash
python telegram_signal_monitor_mt.py my_channel.ini "123,130-135,200"
```

## Parameter List

### A) Environment Parameters

1. `TELEGRAM_API_ID` (required): Telegram API ID.
2. `TELEGRAM_API_HASH` (required): Telegram API hash.
3. `TELEGRAM_PHONE_NUMBER` (optional): Login number, default `+1234567890`.
4. `DATABASE_PATH` (optional): SQLite path, default `telegram_signals.db`.
5. `MT_BASE_PATH` (optional): MetaQuotes terminal base directory.

### B) Chat Config Parameters

1. `CHAT_NAME` (optional): Friendly name, also used as fallback chat identifier.
2. `CHAT_USERNAME` (optional): Telegram username (example `@MyChannel`).
3. `CHAT_ID` (optional): Numeric chat ID or invite link.
4. `DB_SOURCE` (optional): Source label saved in DB, default `Unknown`.
5. `BROKER` (required): Terminal hash folder name used under `MT_BASE_PATH`.
6. `SYMBOL_POSTFIX` (optional): Appended to parsed symbols.
7. `DEFAULT_VOLUME` (optional): Lot size for generated `CREATE` orders, default `0.1`.
8. `MARKET_TYPE` (optional): `MT4` or `MT5` (aliases supported: `MQL4`, `MQL5`, `4`, `5`). Default `MT5`.
9. `SIGNAL_PATTERNS` (optional): Regex dictionary with keys `create_buy` and `create_sell`.
10. `SL_GROUP` (optional): Comma-separated regex group indexes for stop-loss extraction. Default `[4]`.
11. `TP_GROUP` (optional): Comma-separated regex group indexes for take-profit extraction. Default `[6]`.
12. `SYMBOL_MAPPING` (optional): Dictionary mapping incoming signal symbols to broker symbols (stored in DB table `symbol_mappings`).
13. `AI_PROMPT_CUSTOM` (currently informational): Present in config files but not used by `telegram_signal_monitor_mt.py`.
14. `ENABLE_AI_FILTERING` (currently informational): Present in config files but not used by `telegram_signal_monitor_mt.py`.
15. `FALLBACK_TO_REGEX` (currently informational): Present in config files but not used by `telegram_signal_monitor_mt.py`.
16. `MT_BASE_PATH` in config file (currently informational): The script uses environment variable `MT_BASE_PATH`, not this config key.

Minimum required chat config:
- One of `CHAT_USERNAME` or `CHAT_ID`.
- `BROKER`.

## Output Paths

For each chat config, the script computes:

- Input folder: `{MT_BASE_PATH}\{BROKER}\{MQLx}\Files\input`
- Output folder: `{MT_BASE_PATH}\{BROKER}\{MQLx}\Files\output`

Where `{MQLx}` is `MQL4` for MT4 and `MQL5` for MT5.

## Generated JSON Format

Example output file (`<msg_id>.json`):

```json
{
  "action": "CREATE",
  "symbol": "XAUUSDm",
  "type": "MARKET",
  "side": "BUY",
  "volume": 0.1,
  "price": 0.0,
  "sl": 3333.0,
  "tp": 3377.0,
  "broker": "55E2ADC37B5CE866A63476C1AC9C9FD4",
  "msg_id": "12345"
}
```

## Troubleshooting

1. Telegram auth errors: verify `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, `TELEGRAM_PHONE_NUMBER`.
2. Chat not resolved: ensure `CHAT_ID` or `CHAT_USERNAME` is valid.
3. Files not created: verify `MT_BASE_PATH`, `BROKER`, and terminal folder permissions.
4. No signal detected: validate regex in `SIGNAL_PATTERNS` and correct `SL_GROUP`/`TP_GROUP` indexes.