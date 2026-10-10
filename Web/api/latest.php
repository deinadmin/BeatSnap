<?php
declare(strict_types=1);

require dirname(__DIR__) . '/includes/bootstrap.php';

/* Metadata for the newest published release, for update checks from the app. */

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Cache-Control: public, max-age=300');

try {
    $release = release_latest();
} catch (Throwable $error) {
    error_log('BeatSnap API: ' . $error->getMessage());
    http_response_code(503);
    echo json_encode(['error' => 'unavailable']);
    exit;
}

if (!$release) {
    http_response_code(404);
    echo json_encode(['error' => 'no_release']);
    exit;
}

$path = release_local_path($release);
echo json_encode([
    'version'          => $release['version'],
    'build'            => $release['build'],
    'released_at'      => $release['released_at'],
    'minimum_macos'    => $release['min_os'],
    'notes'            => $release['notes'],
    'size'             => $path ? (int) $release['file_size'] : null,
    'sha256'           => $path ? $release['sha256'] : null,
    'download_url'     => base_url() . '/download.php?get=1&version=' . rawurlencode((string) $release['version']),
    'latest_url'       => base_url() . '/download.php?get=1',
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
