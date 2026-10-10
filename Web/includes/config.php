<?php
/*
 * Default configuration. Don't edit this file on the server — copy
 * config.local.sample.php to config.local.php and override values there.
 */
return [
    'site_name'     => 'BeatSnap',
    'author'        => 'Carl Steen',

    // Public URL of the site without a trailing slash, e.g. https://beatsnap.app.
    // Used for absolute links in the update API. Detected from the request if empty.
    'base_url'      => '',

    // Where the SQLite database and uploaded releases live. Keep it outside the
    // web root if your host allows it; the bundled storage/.htaccess denies access otherwise.
    'storage_path'  => dirname(__DIR__) . '/storage',

    // Required to create the first admin account at /admin/setup.php. Leave empty to
    // keep setup disabled. Once an admin exists, setup is disabled regardless.
    'setup_key'     => '',

    // Optional links shown on the landing page.
    'purchase_url'  => '',
    'contact_email' => '',

    'timezone'      => 'Europe/Berlin',

    // Admin sessions expire after this many seconds without activity.
    'session_idle'  => 60 * 60 * 8,

    'allowed_extensions' => ['dmg', 'zip', 'pkg'],
];
