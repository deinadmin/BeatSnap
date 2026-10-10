<?php
declare(strict_types=1);

require __DIR__ . '/includes/bootstrap.php';

/* Sparkle update feed: the newest published release, if it carries an EdDSA signature. */

header('Content-Type: application/xml; charset=utf-8');
header('Cache-Control: public, max-age=300');

function xml(string $value): string
{
    return htmlspecialchars($value, ENT_XML1 | ENT_QUOTES, 'UTF-8');
}

$site = xml((string) config('site_name'));
$item = '';

try {
    $release = release_latest();
    if ($release && release_local_path($release) && !empty($release['ed_signature']) && $release['build'] !== '') {
        $extension = strtolower(pathinfo((string) $release['file_name'], PATHINFO_EXTENSION));
        $url = base_url() . '/downloads/' . config('site_name') . '-' . rawurlencode((string) $release['version']) . '.' . $extension;
        $notes = render_notes((string) $release['notes']);
        $item = sprintf(
            '<item><title>Version %s</title><pubDate>%s</pubDate><sparkle:version>%s</sparkle:version>'
            . '<sparkle:shortVersionString>%s</sparkle:shortVersionString><sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>'
            . '<description><![CDATA[%s]]></description>'
            . '<enclosure url="%s" length="%d" type="application/octet-stream" sparkle:edSignature="%s"/></item>',
            xml((string) $release['version']),
            gmdate(DATE_RFC2822, strtotime((string) $release['released_at'] . ' 12:00:00 UTC') ?: time()),
            xml((string) $release['build']),
            xml((string) $release['version']),
            xml((string) $release['min_os']),
            str_replace(']]>', ']]]]><![CDATA[>', $notes),
            xml($url),
            (int) $release['file_size'],
            xml((string) $release['ed_signature'])
        );
    }
} catch (Throwable $error) {
    error_log('BeatSnap appcast: ' . $error->getMessage());
    http_response_code(503);
}

echo '<?xml version="1.0" encoding="UTF-8"?>' . "\n";
echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
    . "<channel><title>{$site}</title>{$item}</channel></rss>\n";
