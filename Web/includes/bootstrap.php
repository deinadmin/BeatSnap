<?php
declare(strict_types=1);

define('BEATSNAP', true);
define('WEB_ROOT', dirname(__DIR__));

(function (): void {
    $config = require __DIR__ . '/config.php';
    $local = getenv('BEATSNAP_CONFIG') ?: __DIR__ . '/config.local.php';
    if (is_file($local)) {
        $config = array_replace($config, require $local);
    }
    $GLOBALS['beatsnap_config'] = $config;
})();

date_default_timezone_set((string) $GLOBALS['beatsnap_config']['timezone']);

require __DIR__ . '/helpers.php';
require __DIR__ . '/db.php';
require __DIR__ . '/releases.php';
require __DIR__ . '/auth.php';
