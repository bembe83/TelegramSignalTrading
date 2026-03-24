#!/usr/bin/env python3
"""
Database initialization script for Copy Trading Bot.
Creates the required database tables and performs initial setup.
"""
import os
import sqlite3
import sys
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Database path from .env
DB_PATH = os.getenv('DATABASE_PATH', 'telegram_signals.db')

def init_db():
    """Initialize the database with required tables."""
    print(f"Initializing database: {DB_PATH}")

    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()

    # Table for processed messages
    c.execute('''CREATE TABLE IF NOT EXISTS messages (
                    msg_id TEXT PRIMARY KEY,
                    message_text TEXT,
                    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
                    action TEXT,
                    ticket INTEGER,
                    processed BOOLEAN DEFAULT FALSE,
                    source TEXT,
                    full_message TEXT
                 )''')

    # Table for message links (for updates/cancels)
    c.execute('''CREATE TABLE IF NOT EXISTS message_links (
                    msg_id TEXT PRIMARY KEY,
                    linked_msg_id TEXT,
                    FOREIGN KEY (linked_msg_id) REFERENCES messages(msg_id)
                 )''')

    # Table for per-source symbol mappings (signal symbol -> broker symbol)
    c.execute('''CREATE TABLE IF NOT EXISTS symbol_mappings (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source TEXT NOT NULL,
                    signal_symbol TEXT NOT NULL,
                    mapped_symbol TEXT NOT NULL,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(source, signal_symbol)
                 )''')

    # Create indexes for better performance
    c.execute('CREATE INDEX IF NOT EXISTS idx_messages_processed ON messages(processed)')
    c.execute('CREATE INDEX IF NOT EXISTS idx_messages_source ON messages(source)')
    c.execute('CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp)')
    c.execute('CREATE INDEX IF NOT EXISTS idx_symbol_mappings_source ON symbol_mappings(source)')

    conn.commit()
    conn.close()

    print("Database initialized successfully!")
    print("Created tables:")
    print("  - messages: Stores processed trading signals")
    print("  - message_links: Stores relationships between linked messages")
    print("  - symbol_mappings: Stores per-source symbol mapping rules")
    print("Created indexes for optimized queries")

def verify_database():
    """Verify that the database was created correctly."""
    print("\nVerifying database structure...")

    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()

    # Check tables
    c.execute("SELECT name FROM sqlite_master WHERE type='table'")
    tables = c.fetchall()
    table_names = [table[0] for table in tables]

    required_tables = ['messages', 'message_links', 'symbol_mappings']
    for table in required_tables:
        if table in table_names:
            print(f"✓ Table '{table}' exists")
        else:
            print(f"✗ Table '{table}' missing")
            return False

    # Check indexes
    c.execute("SELECT name FROM sqlite_master WHERE type='index'")
    indexes = c.fetchall()
    index_names = [index[0] for index in indexes]

    required_indexes = ['idx_messages_processed', 'idx_messages_source', 'idx_messages_timestamp', 'idx_symbol_mappings_source']
    for index in required_indexes:
        if index in index_names:
            print(f"✓ Index '{index}' exists")
        else:
            print(f"✗ Index '{index}' missing")
            return False

    conn.close()
    print("Database verification completed successfully!")
    return True

def create_directories():
    """Create necessary directories if they don't exist."""
    print("\nCreating necessary directories...")

    # Get base MT4 path
    base_mt4_path = os.getenv('MT4_BASE_PATH', r'C:\Users\YourUsername\AppData\Roaming\MetaQuotes\Terminal')

    # Create a sample broker directory structure (users will need to create their own)
    sample_broker = "SampleBroker"
    directories = [
        f"{base_mt4_path}\\{sample_broker}\\MQL4\\Files\\input",
        f"{base_mt4_path}\\{sample_broker}\\MQL4\\Files\\output",
        f"{base_mt4_path}\\{sample_broker}\\MQL4\\Files\\archive\\input",
        f"{base_mt4_path}\\{sample_broker}\\MQL4\\Files\\archive\\output"
    ]

    for directory in directories:
        try:
            os.makedirs(directory, exist_ok=True)
            print(f"✓ Created directory: {directory}")
        except OSError as e:
            print(f"✗ Failed to create directory {directory}: {e}")

    print("Directory creation completed!")
    print(f"Note: Update your chat config files to use actual broker names instead of '{sample_broker}'")

def main():
    """Main initialization function."""
    print("Copy Trading Bot - Database Initialization")
    print("=" * 50)

    try:
        # Initialize database
        init_db()

        # Verify database
        if not verify_database():
            print("Database verification failed!")
            sys.exit(1)

        # Create directories
        create_directories()

        print("\n" + "=" * 50)
        print("Initialization completed successfully!")
        print("\nNext steps:")
        print("1. Update MT4_BASE_PATH in .env file with your actual MT4 terminal path")
        print("2. Create chat config files for each signal channel")
        print("3. Update broker names in config files")
        print("4. Run telegram_signal_monitor.py with your config file")
        print("5. Run update_db_from_mt4.py with your broker name")

    except Exception as e:
        print(f"Error during initialization: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()