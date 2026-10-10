<?php
declare(strict_types=1);

defined('BEATSNAP') || exit;

function db(): PDO
{
    static $pdo = null;
    if ($pdo instanceof PDO) {
        return $pdo;
    }

    $dir = storage_path();
    if (!is_dir($dir) && !mkdir($dir, 0775, true) && !is_dir($dir)) {
        throw new RuntimeException("Storage directory {$dir} could not be created.");
    }

    $pdo = new PDO('sqlite:' . $dir . '/beatsnap.sqlite', null, null, [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_TIMEOUT            => 5,
    ]);
    $pdo->exec('PRAGMA foreign_keys = ON');
    $pdo->exec('PRAGMA journal_mode = WAL');
    migrate($pdo);
    return $pdo;
}

function migrate(PDO $pdo): void
{
    $version = (int) $pdo->query('PRAGMA user_version')->fetchColumn();

    if ($version < 1) {
        $pdo->exec(<<<'SQL'
            CREATE TABLE IF NOT EXISTS admins (
                id            INTEGER PRIMARY KEY,
                username      TEXT NOT NULL UNIQUE COLLATE NOCASE,
                password_hash TEXT NOT NULL,
                created_at    TEXT NOT NULL,
                last_login_at TEXT
            );
            CREATE TABLE IF NOT EXISTS releases (
                id           INTEGER PRIMARY KEY,
                version      TEXT NOT NULL UNIQUE,
                build        TEXT NOT NULL DEFAULT '',
                notes        TEXT NOT NULL DEFAULT '',
                min_os       TEXT NOT NULL DEFAULT '26.0',
                file_name    TEXT,
                external_url TEXT,
                file_size    INTEGER,
                sha256       TEXT,
                is_published INTEGER NOT NULL DEFAULT 0,
                released_at  TEXT NOT NULL,
                created_at   TEXT NOT NULL,
                updated_at   TEXT NOT NULL,
                downloads    INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS login_attempts (
                ip           TEXT NOT NULL,
                attempted_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS login_attempts_ip ON login_attempts (ip, attempted_at);
            PRAGMA user_version = 1;
            SQL);
    }

    if ($version < 2) {
        $pdo->exec(<<<'SQL'
            CREATE TABLE IF NOT EXISTS api_tokens (
                id           INTEGER PRIMARY KEY,
                name         TEXT NOT NULL,
                token_hash   TEXT NOT NULL UNIQUE,
                created_at   TEXT NOT NULL,
                last_used_at TEXT
            );
            PRAGMA user_version = 2;
            SQL);
    }
}

function now(): string
{
    return date('Y-m-d H:i:s');
}
