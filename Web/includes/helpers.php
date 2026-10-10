<?php
declare(strict_types=1);

defined('BEATSNAP') || exit;

function config(string $key, mixed $default = null): mixed
{
    return $GLOBALS['beatsnap_config'][$key] ?? $default;
}

function e(?string $value): string
{
    return htmlspecialchars($value ?? '', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function storage_path(string $path = ''): string
{
    $root = rtrim((string) config('storage_path'), '/');
    return $path === '' ? $root : $root . '/' . ltrim($path, '/');
}

/** Asset URL relative to the web root, cache-busted by modification time. */
function asset(string $path, string $prefix = ''): string
{
    $file = WEB_ROOT . '/' . ltrim($path, '/');
    $version = is_file($file) ? '?v=' . filemtime($file) : '';
    return $prefix . ltrim($path, '/') . $version;
}

function is_https(): bool
{
    return (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
        || ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https'
        || (int) ($_SERVER['SERVER_PORT'] ?? 0) === 443;
}

/** Absolute URL of the site root, without a trailing slash. */
function base_url(): string
{
    $configured = rtrim((string) config('base_url'), '/');
    if ($configured !== '') {
        return $configured;
    }
    $host = $_SERVER['HTTP_HOST'] ?? 'localhost';
    if (!preg_match('/^[A-Za-z0-9.\-]+(:\d+)?$/', $host)) {
        $host = 'localhost';
    }
    // Scripts live in the web root or exactly one directory below it (admin/, api/).
    $script = str_replace('\\', '/', $_SERVER['SCRIPT_NAME'] ?? '/');
    $dir = rtrim(dirname($script), '/');
    if (preg_match('#/(admin|api)$#', $dir)) {
        $dir = dirname($dir);
    }
    return (is_https() ? 'https' : 'http') . '://' . $host . rtrim($dir, '/');
}

function json_response(array $data, int $status = 200): never
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function redirect(string $location, int $status = 303): never
{
    header('Location: ' . $location, true, $status);
    exit;
}

function start_session(): void
{
    if (session_status() === PHP_SESSION_ACTIVE) {
        return;
    }
    session_name('beatsnap_admin');
    session_set_cookie_params([
        'lifetime' => 0,
        'path'     => '/',
        'secure'   => is_https(),
        'httponly' => true,
        'samesite' => 'Lax',
    ]);
    ini_set('session.use_strict_mode', '1');
    session_start();
}

/** Resumes an existing admin session without handing every visitor a cookie. */
function resume_session(): void
{
    if (isset($_COOKIE['beatsnap_admin'])) {
        start_session();
    }
}

function csrf_token(): string
{
    start_session();
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf'];
}

function csrf_field(): string
{
    return '<input type="hidden" name="csrf" value="' . e(csrf_token()) . '">';
}

function csrf_valid(): bool
{
    start_session();
    $sent = $_POST['csrf'] ?? '';
    return is_string($sent) && !empty($_SESSION['csrf']) && hash_equals($_SESSION['csrf'], $sent);
}

function flash(string $message, string $type = 'success'): void
{
    start_session();
    $_SESSION['flash'][] = ['message' => $message, 'type' => $type];
}

/** @return list<array{message: string, type: string}> */
function take_flashes(): array
{
    start_session();
    $flashes = $_SESSION['flash'] ?? [];
    unset($_SESSION['flash']);
    return $flashes;
}

function client_ip(): string
{
    return (string) ($_SERVER['REMOTE_ADDR'] ?? 'unknown');
}

function format_bytes(?int $bytes): string
{
    if ($bytes === null || $bytes <= 0) {
        return '—';
    }
    $units = ['bytes', 'KB', 'MB', 'GB'];
    $power = min((int) floor(log($bytes, 1000)), count($units) - 1);
    $value = $bytes / (1000 ** $power);
    return ($power === 0 ? (string) $bytes : number_format($value, $value < 10 ? 1 : 0)) . ' ' . $units[$power];
}

function format_date(?string $date): string
{
    if (!$date) {
        return '—';
    }
    $time = strtotime($date);
    return $time ? date('j F Y', $time) : $date;
}

/**
 * Release notes are plain text: lines starting with "-" or "•" become list items,
 * everything else becomes a paragraph.
 */
function render_notes(string $notes): string
{
    $html = '';
    $list = [];
    $flush = function () use (&$list, &$html): void {
        if ($list) {
            $html .= '<ul>' . implode('', array_map(fn ($item) => '<li>' . e($item) . '</li>', $list)) . '</ul>';
            $list = [];
        }
    };
    foreach (preg_split('/\R/', trim($notes)) ?: [] as $line) {
        $line = trim($line);
        if ($line === '') {
            $flush();
        } elseif (preg_match('/^[-•*]\s*(.+)$/u', $line, $match)) {
            $list[] = $match[1];
        } else {
            $flush();
            $html .= '<p>' . e($line) . '</p>';
        }
    }
    $flush();
    return $html;
}

function ini_bytes(string $key): int
{
    $value = trim((string) ini_get($key));
    if ($value === '' || $value === '-1') {
        return PHP_INT_MAX;
    }
    $number = (int) $value;
    return match (strtolower(substr($value, -1))) {
        'g' => $number * 1024 ** 3,
        'm' => $number * 1024 ** 2,
        'k' => $number * 1024,
        default => $number,
    };
}

function max_upload_bytes(): int
{
    return min(ini_bytes('upload_max_filesize'), ini_bytes('post_max_size'));
}
