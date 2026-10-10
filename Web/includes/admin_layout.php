<?php
declare(strict_types=1);

defined('BEATSNAP') || exit;

function admin_header(string $title, ?array $admin = null, string $active = ''): void
{
    $site = config('site_name');
    $nav = [
        'releases' => ['index.php', 'Releases'],
        'account'  => ['account.php', 'Account'],
    ];
    ?>
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex, nofollow">
    <meta name="color-scheme" content="light dark">
    <title><?= e($title) ?> · <?= e($site) ?> Admin</title>
    <link rel="icon" href="<?= e(asset('assets/img/favicon.png', '../')) ?>">
    <link rel="stylesheet" href="<?= e(asset('assets/css/admin.css', '../')) ?>">
    <script src="<?= e(asset('assets/js/admin.js', '../')) ?>" defer></script>
</head>
<body class="<?= $admin ? 'admin' : 'admin admin--bare' ?>">
<?php if ($admin): ?>
<header class="toolbar">
    <div class="toolbar__inner">
        <a class="brand" href="index.php">
            <img src="<?= e(asset('assets/img/app-icon.png', '../')) ?>" width="28" height="28" alt="">
            <span><?= e($site) ?></span>
        </a>
        <nav class="segmented" aria-label="Admin">
            <?php foreach ($nav as $key => [$href, $label]): ?>
                <a href="<?= $href ?>"<?= $key === $active ? ' aria-current="page"' : '' ?>><?= $label ?></a>
            <?php endforeach; ?>
        </nav>
        <div class="toolbar__end">
            <a class="link" href="../" target="_blank" rel="noopener">View site</a>
            <form method="post" action="logout.php">
                <?= csrf_field() ?>
                <button class="button button--plain" type="submit">Sign out</button>
            </form>
        </div>
    </div>
</header>
<?php endif; ?>
<main class="<?= $admin ? 'page' : 'auth' ?>">
<?php foreach (take_flashes() as $flash): ?>
    <div class="banner banner--<?= e($flash['type']) ?>" role="status"><?= e($flash['message']) ?></div>
<?php endforeach;
}

function admin_footer(): void
{
    ?>
</main>
</body>
</html>
<?php
}

function admin_error(string $message): void
{
    echo '<div class="banner banner--error" role="alert">' . e($message) . '</div>';
}
