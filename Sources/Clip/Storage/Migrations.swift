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

        // v2: image support.
        // - items.kind:      'text' | 'image'. Existing rows default to 'text'.
        // - items.blob_id:   FK into clip_blobs (NULL for text rows).
        // - items.mime_type: 'image/png' | 'image/tiff' | 'application/pdf'
        //                    for images; NULL for text.
        // - clip_blobs:      content-addressed binary store keyed by sha256
        //                    so identical images dedup across copies.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                ALTER TABLE items ADD COLUMN kind TEXT NOT NULL DEFAULT 'text';
            """)
            try db.execute(sql: """
                ALTER TABLE items ADD COLUMN blob_id INTEGER;
            """)
            try db.execute(sql: """
                ALTER TABLE items ADD COLUMN mime_type TEXT;
            """)
            try db.execute(sql: """
                CREATE TABLE clip_blobs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    sha256 TEXT NOT NULL UNIQUE,
                    bytes BLOB NOT NULL,
                    byte_size INTEGER NOT NULL,
                    created_at INTEGER NOT NULL
                );
            """)
            try db.execute(sql: "CREATE INDEX idx_blobs_sha256 ON clip_blobs(sha256);")
            try db.execute(sql: "CREATE INDEX idx_items_kind ON items(kind, created_at DESC);")
        }

        // v3: cloud sync columns + tables.
        // Spec: docs/superpowers/specs/2026-05-02-clip-cloud-sync.md §5.1
        migrator.registerMigration("v3") { db in
            // items: 6 new columns
            try db.execute(sql: "ALTER TABLE items ADD COLUMN cloud_id TEXT;")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN cloud_updated_at INTEGER;")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN cloud_synced_at INTEGER;")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN cloud_blob_key TEXT;")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN sync_excluded INTEGER NOT NULL DEFAULT 0;")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN device_id TEXT;")

            // Partial unique index: enforce 1 cloud_id per row, but allow many NULL
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_items_cloud_id ON items(cloud_id) WHERE cloud_id IS NOT NULL;
            """)

            // tombstones (local-side; prevents capture-side resurrection)
            try db.execute(sql: """
                CREATE TABLE tombstones (
                    content_hash      TEXT PRIMARY KEY,
                    cloud_id          TEXT NOT NULL,
                    tombstoned_at     INTEGER NOT NULL,
                    cloud_updated_at  INTEGER NOT NULL
                );
            """)

            // sync_queue
            try db.execute(sql: """
                CREATE TABLE sync_queue (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    op          TEXT NOT NULL,
                    target_key  TEXT NOT NULL,
                    attempts    INTEGER NOT NULL DEFAULT 0,
                    next_try_at INTEGER NOT NULL,
                    last_error  TEXT,
                    enqueued_at INTEGER NOT NULL
                );
            """)
            try db.execute(sql: "CREATE INDEX idx_sync_queue_next ON sync_queue(next_try_at);")

            // sync_state — generic kv (device_id, cloud_pull_cursor, kdf_*, etc.)
            try db.execute(sql: """
                CREATE TABLE sync_state (
                    key   TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
            """)
        }
    }
}
