<?php
/*
 * Copy to config.local.php and adjust. Only keys you set here override the defaults
 * in config.php. config.local.php is ignored by git.
 */
return [
    'base_url'     => 'https://beatsnap.example.com',

    // Any long random string, e.g. the output of `openssl rand -hex 24`.
    // Visit /admin/setup.php once, enter it, and create your account.
    'setup_key'    => '',

    // 'storage_path'  => '/home/you/beatsnap-storage',
    // 'purchase_url'  => 'https://…',
    // 'contact_email' => 'hello@example.com',
];
