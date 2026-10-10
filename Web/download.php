<?php
declare(strict_types=1);

require __DIR__ . '/includes/bootstrap.php';

/*
 * /download.php                 → newest published release
 * /download.php?version=1.2.0   → a specific published release
 * Add ?get=1 to skip the confirmation page and receive the file directly.
 * /download.php?id=7            → any release, including drafts (signed-in admins only)
 */

function notice(string $heading, string $text, string $buttonLabel, string $buttonHref, string $linkLabel, string $linkHref, int $status = 200, ?string $autoStart = null): never
{
    http_response_code($status);
    header('Cache-Control: no-store');
    $css = e(asset('assets/css/site.css'));
    $icon = e(asset('assets/img/app-icon.png'));
    $site = e(config('site_name'));
    [$heading, $text, $buttonLabel, $buttonHref, $linkLabel, $linkHref] =
        array_map('e', [$heading, $text, $buttonLabel, $buttonHref, $linkLabel, $linkHref]);
    $link = $linkLabel !== '' ? "<a class=\"link-arrow link-back\" href=\"{$linkHref}\">{$linkLabel}</a>" : '';
    $start = $autoStart !== null ? e($autoStart) : '';
    $fallback = $start !== '' ? "<noscript><meta http-equiv=\"refresh\" content=\"0;url={$start}\"></noscript>" : '';
    $script = $start !== ''
        ? "<script>var f=document.createElement('iframe');f.hidden=true;f.src='{$start}';document.body.appendChild(f)</script>"
        : '';
    echo <<<HTML
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>{$heading} · {$site}</title><link rel="stylesheet" href="{$css}">{$fallback}</head>
        <body class="notice-page"><main class="notice" role="status">
        <img src="{$icon}" width="96" height="96" alt="">
        <h1>{$heading}</h1>
        <p>{$text}</p>
        <a class="button" href="{$buttonHref}">{$buttonLabel}</a>
        {$link}
        </main>{$script}</body></html>
        HTML;
    exit;
}

function not_found(string $message): never
{
    notice($message, 'Check back soon — the newest version will be available here.',
        'Back to ' . config('site_name'), './', '', '', 404);
}

try {
    $countable = true;
    if (isset($_GET['id'])) {
        if (!viewer_is_admin()) {
            not_found('That download isn’t available.');
        }
        $release = release_find((int) $_GET['id']);
        $countable = false;
    } elseif (isset($_GET['version']) && is_string($_GET['version'])) {
        $release = release_find_by_version($_GET['version']);
        if ($release && !$release['is_published']) {
            $release = null;
        }
    } else {
        $release = release_latest();
    }
} catch (Throwable $error) {
    error_log('BeatSnap download: ' . $error->getMessage());
    not_found('Downloads are temporarily unavailable.');
}

if (!$release || !release_is_downloadable($release)) {
    not_found(isset($_GET['version']) ? 'That version isn’t available.' : 'BeatSnap isn’t available to download yet.');
}

$count = function () use ($release, $countable): void {
    if ($countable) {
        try {
            release_count_download((int) $release['id']);
        } catch (Throwable $error) {
            error_log('BeatSnap download count: ' . $error->getMessage());
        }
    }
};

$isDirect = isset($_GET['get']) || isset($_GET['id']) || ($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'GET';
if (!$isDirect) {
    $query = 'get=1' . (isset($_GET['version']) ? '&version=' . rawurlencode((string) $_GET['version']) : '');
    notice(config('site_name') . ' has started downloading.',
        'Open the file from your Downloads folder, then drag BeatSnap into Applications. Nothing happened? Give it another go.',
        'Download again', 'download.php?' . $query, 'Back to the site', './', 200, 'download.php?' . $query);
}

if ($path = release_local_path($release)) {
    send_file($path, release_download_name($release), $count);
}

if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'HEAD') {
    $count();
}
header('Cache-Control: no-store');
redirect((string) $release['external_url'], 302);
