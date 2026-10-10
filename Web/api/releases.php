<?php
declare(strict_types=1);

require dirname(__DIR__) . '/includes/bootstrap.php';

/*
 * Release upload API for Scripts/release.sh. Authenticate with an X-BeatSnap-Token header
 * (create tokens under Admin → Account).
 *
 * GET  ?version=1.2.0              → upload limits and whether that version already exists
 * POST action=chunk                → upload_id, offset, chunk (file): appends one piece of the build
 * POST action=finish               → upload_id, file_name, size, sha256, version, build, min_os, notes:
 *                                    verifies the assembled file and creates (or refreshes) a draft
 *
 * Chunks keep each request under the host's PHP upload limit, so large builds work anywhere.
 */

const UPLOAD_ID_PATTERN = '/^[a-f0-9]{32}$/';
const MAX_CHUNK_BYTES = 16 * 1024 * 1024;

require_api_token();

function uploads_dir(): string
{
    $dir = storage_path('uploads');
    if (!is_dir($dir) && !mkdir($dir, 0775, true) && !is_dir($dir)) {
        json_response(['error' => 'The uploads folder could not be created.'], 500);
    }
    foreach (glob($dir . '/*.part') ?: [] as $stale) {
        if (filemtime($stale) < time() - 86400) {
            @unlink($stale);
        }
    }
    return $dir;
}

function part_path(): string
{
    $id = (string) ($_POST['upload_id'] ?? '');
    if (!preg_match(UPLOAD_ID_PATTERN, $id)) {
        json_response(['error' => 'upload_id must be 32 lowercase hex characters.'], 422);
    }
    return uploads_dir() . '/' . $id . '.part';
}

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

if ($method === 'GET') {
    $version = (string) ($_GET['version'] ?? '');
    $release = $version !== '' ? release_find_by_version($version) : null;
    json_response([
        'max_chunk_bytes' => max(256 * 1024, min(MAX_CHUNK_BYTES, max_upload_bytes() - 512 * 1024)),
        'allowed_extensions' => config('allowed_extensions'),
        'release' => $release ? [
            'id'        => (int) $release['id'],
            'version'   => $release['version'],
            'published' => (bool) $release['is_published'],
            'edit_url'  => base_url() . '/admin/release.php?id=' . (int) $release['id'],
        ] : null,
    ]);
}

if ($method !== 'POST') {
    json_response(['error' => 'Method not allowed.'], 405);
}
if (empty($_POST) && (int) ($_SERVER['CONTENT_LENGTH'] ?? 0) > 0) {
    json_response(['error' => 'The request exceeded the server’s upload limit. Use smaller chunks.'], 413);
}

switch ($_POST['action'] ?? '') {
    case 'chunk':
        $path = part_path();
        $offset = (int) ($_POST['offset'] ?? -1);
        $chunk = $_FILES['chunk'] ?? null;
        if (!$chunk || $chunk['error'] !== UPLOAD_ERR_OK) {
            json_response(['error' => 'The chunk didn’t arrive (upload error ' . (int) ($chunk['error'] ?? -1) . ').'], 422);
        }
        clearstatcache();
        $size = is_file($path) ? (int) filesize($path) : 0;
        if ($offset < 0 || $offset > $size) {
            json_response(['error' => 'Unexpected offset.', 'received' => $size], 409);
        }
        $out = fopen($path, 'c+b');
        $in = fopen($chunk['tmp_name'], 'rb');
        if (!$out || !$in || !flock($out, LOCK_EX)) {
            json_response(['error' => 'The chunk could not be stored.'], 500);
        }
        // A retried chunk overwrites whatever arrived of its previous attempt.
        ftruncate($out, $offset);
        fseek($out, $offset);
        stream_copy_to_stream($in, $out);
        fflush($out);
        $received = ftell($out);
        flock($out, LOCK_UN);
        fclose($out);
        fclose($in);
        json_response(['received' => $received]);

    case 'finish':
        $path = part_path();
        $fields = [
            'version'     => trim((string) ($_POST['version'] ?? '')),
            'build'       => trim((string) ($_POST['build'] ?? '')),
            'min_os'      => trim((string) ($_POST['min_os'] ?? '26.0')),
            'released_at' => date('Y-m-d'),
        ];
        $notes = isset($_POST['notes']) ? trim(str_replace("\r\n", "\n", (string) $_POST['notes'])) : null;
        $extension = strtolower(pathinfo((string) ($_POST['file_name'] ?? ''), PATHINFO_EXTENSION));

        if ($message = release_fields_error($fields)) {
            json_response(['error' => $message], 422);
        }
        if (!in_array($extension, config('allowed_extensions'), true)) {
            json_response(['error' => 'Unsupported file type.'], 422);
        }
        if (!is_file($path)) {
            json_response(['error' => 'No upload found for that upload_id.'], 404);
        }
        clearstatcache();
        if ((int) filesize($path) !== (int) ($_POST['size'] ?? -1)) {
            json_response(['error' => 'The uploaded size doesn’t match.', 'received' => (int) filesize($path)], 422);
        }
        $sha256 = hash_file('sha256', $path);
        if (!hash_equals($sha256, strtolower((string) ($_POST['sha256'] ?? '')))) {
            @unlink($path);
            json_response(['error' => 'The checksum doesn’t match; the upload was discarded. Please try again.'], 422);
        }

        $existing = release_find_by_version($fields['version']);
        if ($existing && $existing['is_published']) {
            @unlink($path);
            json_response(['error' => "Version {$fields['version']} is already published. Bump the version or unpublish it first."], 409);
        }

        $id = $existing ? (int) $existing['id'] : null;
        $name = release_target_name($fields['version'], $extension, $id);
        if (!rename($path, releases_dir() . '/' . $name)) {
            json_response(['error' => 'The build could not be moved into the releases folder.'], 500);
        }

        $previousFile = $existing ? release_local_path($existing) : null;
        $record = $existing ? array_merge($existing, $fields) : $fields + ['notes' => '', 'is_published' => 0];
        if ($notes !== null && $notes !== '') {
            $record['notes'] = $notes;
        }
        if ($existing) {
            $record['released_at'] = $existing['released_at'];
        }
        $record = array_merge($record, [
            'file_name'    => $name,
            'external_url' => null,
            'file_size'    => (int) filesize(releases_dir() . '/' . $name),
            'sha256'       => $sha256,
            'is_published' => 0,
        ]);
        $id = release_save($record, $id);

        if ($previousFile && basename($previousFile) !== $name && !file_is_referenced(basename($previousFile))) {
            @unlink($previousFile);
        }

        json_response([
            'id'       => $id,
            'version'  => $fields['version'],
            'replaced' => (bool) $existing,
            'size'     => $record['file_size'],
            'sha256'   => $sha256,
            'edit_url' => base_url() . '/admin/release.php?id=' . $id,
        ], $existing ? 200 : 201);

    default:
        json_response(['error' => 'Unknown action.'], 422);
}
