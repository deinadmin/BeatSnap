<?php
declare(strict_types=1);

defined('BEATSNAP') || exit;

const LOGIN_MAX_ATTEMPTS = 5;
const LOGIN_WINDOW_SECONDS = 15 * 60;
const PASSWORD_MIN_LENGTH = 10;

function admin_count(): int
{
    return (int) db()->query('SELECT COUNT(*) FROM admins')->fetchColumn();
}

function admin_create(string $username, string $password): int
{
    db()->prepare('INSERT INTO admins (username, password_hash, created_at) VALUES (?, ?, ?)')
        ->execute([$username, password_hash($password, PASSWORD_DEFAULT), now()]);
    return (int) db()->lastInsertId();
}

function admin_find(int $id): ?array
{
    $statement = db()->prepare('SELECT * FROM admins WHERE id = ?');
    $statement->execute([$id]);
    return $statement->fetch() ?: null;
}

function login_locked_out(string $ip): bool
{
    $statement = db()->prepare('SELECT COUNT(*) FROM login_attempts WHERE ip = ? AND attempted_at > ?');
    $statement->execute([$ip, time() - LOGIN_WINDOW_SECONDS]);
    return (int) $statement->fetchColumn() >= LOGIN_MAX_ATTEMPTS;
}

/** Returns null on success, or a message describing why the login was refused. */
function attempt_login(string $username, string $password): ?string
{
    $ip = client_ip();
    db()->prepare('DELETE FROM login_attempts WHERE attempted_at < ?')->execute([time() - LOGIN_WINDOW_SECONDS]);
    if (login_locked_out($ip)) {
        return 'Too many attempts. Try again in 15 minutes.';
    }

    $statement = db()->prepare('SELECT * FROM admins WHERE username = ?');
    $statement->execute([$username]);
    $admin = $statement->fetch() ?: null;

    // Verify against a throwaway hash for unknown users so timing doesn't reveal which names exist.
    $hash = $admin['password_hash'] ?? password_hash(random_bytes(16), PASSWORD_DEFAULT);
    if (!password_verify($password, $hash) || !$admin) {
        db()->prepare('INSERT INTO login_attempts (ip, attempted_at) VALUES (?, ?)')->execute([$ip, time()]);
        return 'The username or password is incorrect.';
    }

    if (password_needs_rehash($admin['password_hash'], PASSWORD_DEFAULT)) {
        db()->prepare('UPDATE admins SET password_hash = ? WHERE id = ?')
            ->execute([password_hash($password, PASSWORD_DEFAULT), $admin['id']]);
    }
    db()->prepare('DELETE FROM login_attempts WHERE ip = ?')->execute([$ip]);
    db()->prepare('UPDATE admins SET last_login_at = ? WHERE id = ?')->execute([now(), $admin['id']]);
    log_in((int) $admin['id']);
    return null;
}

function log_in(int $adminId): void
{
    start_session();
    session_regenerate_id(true);
    $_SESSION['admin_id'] = $adminId;
    $_SESSION['last_seen'] = time();
    unset($_SESSION['csrf']);
}

function log_out(): void
{
    start_session();
    $_SESSION = [];
    $params = session_get_cookie_params();
    setcookie(session_name(), '', [
        'expires'  => time() - 3600,
        'path'     => $params['path'],
        'secure'   => $params['secure'],
        'httponly' => true,
        'samesite' => $params['samesite'],
    ]);
    session_destroy();
}

function current_admin(): ?array
{
    if (session_status() !== PHP_SESSION_ACTIVE || empty($_SESSION['admin_id'])) {
        return null;
    }
    if (time() - (int) ($_SESSION['last_seen'] ?? 0) > (int) config('session_idle')) {
        $_SESSION = [];
        return null;
    }
    $admin = admin_find((int) $_SESSION['admin_id']);
    if ($admin) {
        $_SESSION['last_seen'] = time();
    }
    return $admin;
}

/** For the public site: true when the visitor is a signed-in admin, without starting new sessions. */
function viewer_is_admin(): bool
{
    try {
        resume_session();
        return current_admin() !== null;
    } catch (Throwable) {
        return false;
    }
}

function require_admin(): array
{
    start_session();
    $admin = current_admin();
    if (!$admin) {
        redirect(admin_count() === 0 ? 'setup.php' : 'login.php');
    }
    header('Cache-Control: no-store');
    header('X-Frame-Options: DENY');
    return $admin;
}

/** Creates a token for the release script. Only its hash is stored; the token is returned once. */
function api_token_create(string $name): string
{
    $token = 'bsk_' . bin2hex(random_bytes(24));
    db()->prepare('INSERT INTO api_tokens (name, token_hash, created_at) VALUES (?, ?, ?)')
        ->execute([$name, hash('sha256', $token), now()]);
    return $token;
}

/** @return list<array<string, mixed>> */
function api_tokens(): array
{
    return db()->query('SELECT id, name, created_at, last_used_at FROM api_tokens ORDER BY id DESC')->fetchAll();
}

function api_token_revoke(int $id): void
{
    db()->prepare('DELETE FROM api_tokens WHERE id = ?')->execute([$id]);
}

/** Authenticates an API request by its X-BeatSnap-Token header, or ends it with a JSON error. */
function require_api_token(): array
{
    $ip = client_ip();
    if (login_locked_out($ip)) {
        json_response(['error' => 'Too many failed attempts. Try again in 15 minutes.'], 429);
    }
    $token = (string) ($_SERVER['HTTP_X_BEATSNAP_TOKEN'] ?? '');
    $statement = db()->prepare('SELECT * FROM api_tokens WHERE token_hash = ?');
    $statement->execute([hash('sha256', $token)]);
    $row = $token !== '' ? $statement->fetch() : false;
    if (!$row) {
        db()->prepare('INSERT INTO login_attempts (ip, attempted_at) VALUES (?, ?)')->execute([$ip, time()]);
        json_response(['error' => 'Missing or invalid API token.'], 401);
    }
    db()->prepare('UPDATE api_tokens SET last_used_at = ? WHERE id = ?')->execute([now(), $row['id']]);
    return $row;
}

function change_password(int $adminId, string $current, string $new): ?string
{
    $admin = admin_find($adminId);
    if (!$admin || !password_verify($current, $admin['password_hash'])) {
        return 'Your current password is incorrect.';
    }
    if (strlen($new) < PASSWORD_MIN_LENGTH) {
        return 'The new password must be at least ' . PASSWORD_MIN_LENGTH . ' characters.';
    }
    db()->prepare('UPDATE admins SET password_hash = ? WHERE id = ?')
        ->execute([password_hash($new, PASSWORD_DEFAULT), $adminId]);
    session_regenerate_id(true);
    return null;
}
