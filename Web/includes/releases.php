<?php
declare(strict_types=1);

defined('BEATSNAP') || exit;

const VERSION_PATTERN = '/^\d+(\.\d+){0,3}(-[0-9A-Za-z.\-]+)?$/';

/** Null when the release fields are valid, otherwise a message describing the first problem. */
function release_fields_error(array $fields): ?string
{
    if (!preg_match(VERSION_PATTERN, (string) ($fields['version'] ?? ''))) {
        return 'Enter a version like 1.2 or 1.2.3 (optionally with a suffix such as 1.3.0-beta.1).';
    }
    if (!preg_match('/^[0-9A-Za-z.\-]{0,32}$/', (string) ($fields['build'] ?? ''))) {
        return 'The build number may only contain letters, numbers, dots and dashes.';
    }
    if (!preg_match('/^\d{1,2}(\.\d+){0,2}$/', (string) ($fields['min_os'] ?? ''))) {
        return 'Enter the minimum macOS version as a number, such as 26.0.';
    }
    if (!DateTime::createFromFormat('!Y-m-d', (string) ($fields['released_at'] ?? ''))) {
        return 'Choose a release date.';
    }
    return null;
}

function releases_dir(): string
{
    $dir = storage_path('releases');
    if (!is_dir($dir) && !mkdir($dir, 0775, true) && !is_dir($dir)) {
        throw new RuntimeException("Releases directory {$dir} could not be created.");
    }
    return $dir;
}

/** @param list<array<string, mixed>> $releases */
function sort_releases(array $releases): array
{
    usort($releases, fn ($a, $b) => version_compare((string) $b['version'], (string) $a['version']));
    return $releases;
}

/** @return list<array<string, mixed>> Newest version first. */
function releases_all(): array
{
    return sort_releases(db()->query('SELECT * FROM releases')->fetchAll());
}

/** @return list<array<string, mixed>> Newest version first. */
function releases_published(): array
{
    return sort_releases(db()->query('SELECT * FROM releases WHERE is_published = 1')->fetchAll());
}

/** The highest published version that actually has something to download. */
function release_latest(): ?array
{
    foreach (releases_published() as $release) {
        if (release_is_downloadable($release)) {
            return $release;
        }
    }
    return null;
}

function release_find(int $id): ?array
{
    $statement = db()->prepare('SELECT * FROM releases WHERE id = ?');
    $statement->execute([$id]);
    return $statement->fetch() ?: null;
}

function release_find_by_version(string $version): ?array
{
    $statement = db()->prepare('SELECT * FROM releases WHERE version = ?');
    $statement->execute([$version]);
    return $statement->fetch() ?: null;
}

function release_local_path(array $release): ?string
{
    $name = (string) ($release['file_name'] ?? '');
    if ($name === '' || basename($name) !== $name) {
        return null;
    }
    $path = releases_dir() . '/' . $name;
    return is_file($path) ? $path : null;
}

function release_is_downloadable(array $release): bool
{
    return !empty($release['external_url']) || release_local_path($release) !== null;
}

function release_download_name(array $release): string
{
    $extension = pathinfo((string) ($release['file_name'] ?? ''), PATHINFO_EXTENSION) ?: 'dmg';
    return config('site_name') . '-' . $release['version'] . '.' . strtolower($extension);
}

function release_save(array $fields, ?int $id = null): int
{
    $columns = ['version', 'build', 'notes', 'min_os', 'file_name', 'external_url',
                'file_size', 'sha256', 'is_published', 'released_at'];
    $values = array_intersect_key($fields, array_flip($columns));
    $values['updated_at'] = now();

    if ($id === null) {
        $values['created_at'] = $values['updated_at'];
        $names = array_keys($values);
        $sql = sprintf('INSERT INTO releases (%s) VALUES (%s)',
            implode(', ', $names), implode(', ', array_map(fn ($n) => ':' . $n, $names)));
        db()->prepare($sql)->execute($values);
        return (int) db()->lastInsertId();
    }

    $assignments = implode(', ', array_map(fn ($n) => "{$n} = :{$n}", array_keys($values)));
    $values['id'] = $id;
    db()->prepare("UPDATE releases SET {$assignments} WHERE id = :id")->execute($values);
    return $id;
}

function release_set_published(int $id, bool $published): void
{
    db()->prepare('UPDATE releases SET is_published = ?, updated_at = ? WHERE id = ?')
        ->execute([$published ? 1 : 0, now(), $id]);
}

function release_delete(int $id, bool $deleteFile): void
{
    $release = release_find($id);
    if (!$release) {
        return;
    }
    db()->prepare('DELETE FROM releases WHERE id = ?')->execute([$id]);
    if ($deleteFile && ($path = release_local_path($release)) && !file_is_referenced(basename($path))) {
        @unlink($path);
    }
}

function release_count_download(int $id): void
{
    db()->prepare('UPDATE releases SET downloads = downloads + 1 WHERE id = ?')->execute([$id]);
}

function file_is_referenced(string $fileName, ?int $exceptId = null): bool
{
    $statement = db()->prepare('SELECT COUNT(*) FROM releases WHERE file_name = ? AND id IS NOT ?');
    $statement->execute([$fileName, $exceptId]);
    return (int) $statement->fetchColumn() > 0;
}

/**
 * Files in the releases folder that no release points at — typically builds uploaded
 * over FTP/SFTP because they exceed PHP's upload limit.
 *
 * @return list<array{name: string, size: int}>
 */
function unattached_release_files(): array
{
    $allowed = config('allowed_extensions');
    $used = array_flip(array_filter(db()->query('SELECT file_name FROM releases')->fetchAll(PDO::FETCH_COLUMN)));
    $files = [];
    foreach (scandir(releases_dir()) ?: [] as $name) {
        $path = releases_dir() . '/' . $name;
        if ($name[0] === '.' || !is_file($path) || isset($used[$name])) {
            continue;
        }
        if (in_array(strtolower(pathinfo($name, PATHINFO_EXTENSION)), $allowed, true)) {
            $files[] = ['name' => $name, 'size' => (int) filesize($path)];
        }
    }
    return $files;
}

/** A file name in the releases folder that won't overwrite another release's file. */
function release_target_name(string $version, string $extension, ?int $releaseId): string
{
    $base = config('site_name') . '-' . preg_replace('/[^0-9A-Za-z.\-]/', '', $version);
    $name = "{$base}.{$extension}";
    for ($n = 2; is_file(releases_dir() . '/' . $name) && file_is_referenced($name, $releaseId); $n++) {
        $name = "{$base}-{$n}.{$extension}";
    }
    return $name;
}

/** Streams a file with single-range support so interrupted downloads can resume. */
function send_file(string $path, string $downloadName, callable $onFullDownload): never
{
    $size = (int) filesize($path);
    $start = 0;
    $end = $size - 1;
    $partial = false;

    if (isset($_SERVER['HTTP_RANGE']) && preg_match('/^bytes=(\d*)-(\d*)$/', $_SERVER['HTTP_RANGE'], $m)) {
        if ($m[1] === '' && $m[2] !== '') {
            $start = max(0, $size - (int) $m[2]);
        } else {
            $start = (int) $m[1];
            $end = $m[2] === '' ? $end : min((int) $m[2], $end);
        }
        if ($start > $end || $start >= $size) {
            header("Content-Range: bytes */{$size}", true, 416);
            exit;
        }
        $partial = true;
    }

    $type = match (strtolower(pathinfo($path, PATHINFO_EXTENSION))) {
        'dmg' => 'application/x-apple-diskimage',
        'zip' => 'application/zip',
        'pkg' => 'application/vnd.apple.installer+xml',
        default => 'application/octet-stream',
    };

    $isHead = ($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'HEAD';
    if (!$isHead && $start === 0) {
        $onFullDownload();
    }

    while (ob_get_level() > 0) {
        ob_end_clean();
    }
    if ($partial) {
        http_response_code(206);
        header("Content-Range: bytes {$start}-{$end}/{$size}");
    }
    header('Content-Type: ' . $type);
    header('Content-Length: ' . ($end - $start + 1));
    header('Content-Disposition: attachment; filename="' . addcslashes($downloadName, '"\\') . '"');
    header('Accept-Ranges: bytes');
    header('Cache-Control: no-store');
    header('X-Content-Type-Options: nosniff');
    if ($isHead) {
        exit;
    }

    set_time_limit(0);
    $handle = fopen($path, 'rb');
    fseek($handle, $start);
    $remaining = $end - $start + 1;
    while ($remaining > 0 && !feof($handle) && !connection_aborted()) {
        $chunk = fread($handle, (int) min(1 << 20, $remaining));
        if ($chunk === false) {
            break;
        }
        echo $chunk;
        flush();
        $remaining -= strlen($chunk);
    }
    fclose($handle);
    exit;
}
