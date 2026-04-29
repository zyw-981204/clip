import GRDB

enum Migrations {
    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE items (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    content TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    source_bundle_id TEXT,
                    source_app_name TEXT,
                    created_at INTEGER NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    byte_size INTEGER NOT NULL,
                    truncated INTEGER NOT NULL DEFAULT 0
                );
            """)
            try db.execute(sql: "CREATE INDEX idx_items_created ON items(created_at DESC);")
            try db.execute(sql: "CREATE INDEX idx_items_hash ON items(content_hash);")
            try db.execute(sql: "CREATE INDEX idx_items_pinned ON items(pinned, created_at DESC);")
            try db.execute(sql: """
                CREATE TABLE blacklist (
                    bundle_id TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    added_at INTEGER NOT NULL
                );
            """)
        }
    }
}
