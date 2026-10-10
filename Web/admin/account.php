<?php
declare(strict_types=1);

require dirname(__DIR__) . '/includes/bootstrap.php';
require dirname(__DIR__) . '/includes/admin_layout.php';

$admin = require_admin();
$error = null;

if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['token_action'])) {
    if (!csrf_valid()) {
        flash('Your session expired. Please try again.', 'error');
    } elseif ($_POST['token_action'] === 'create') {
        $name = trim((string) ($_POST['token_name'] ?? '')) ?: 'Release script';
        $_SESSION['new_api_token'] = api_token_create(mb_substr($name, 0, 60));
        flash("Token “{$name}” created. Copy it now — it won’t be shown again.");
    } elseif ($_POST['token_action'] === 'revoke') {
        api_token_revoke((int) ($_POST['token_id'] ?? 0));
        flash('The token was revoked.');
    }
    redirect('account.php');
}

$newToken = $_SESSION['new_api_token'] ?? null;
unset($_SESSION['new_api_token']);

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (!csrf_valid()) {
        $error = 'Your session expired. Please try again.';
    } elseif (($_POST['new_password'] ?? '') !== ($_POST['confirm_password'] ?? '')) {
        $error = 'The new passwords don’t match.';
    } else {
        $error = change_password((int) $admin['id'], (string) ($_POST['current_password'] ?? ''), (string) $_POST['new_password']);
        if ($error === null) {
            flash('Your password was changed.');
            redirect('account.php');
        }
    }
}

admin_header('Account', $admin, 'account');
?>
<div class="page-head">
    <div>
        <h1>Account</h1>
        <p class="muted">Signed in as <strong><?= e($admin['username']) ?></strong><?php if ($admin['last_login_at']): ?> · last sign-in <?= e(format_date($admin['last_login_at'])) ?><?php endif; ?></p>
    </div>
</div>

<?php if ($error) admin_error($error); ?>

<form method="post">
    <?= csrf_field() ?>
    <input type="text" name="username" value="<?= e($admin['username']) ?>" autocomplete="username" hidden>
    <h2 class="group-title">Change Password</h2>
    <section class="group">
        <label class="row row--field"><span>Current</span>
            <input type="password" name="current_password" autocomplete="current-password" required></label>
        <label class="row row--field"><span>New</span>
            <input type="password" name="new_password" autocomplete="new-password" minlength="<?= PASSWORD_MIN_LENGTH ?>" placeholder="<?= PASSWORD_MIN_LENGTH ?>+ characters" required></label>
        <label class="row row--field"><span>Confirm</span>
            <input type="password" name="confirm_password" autocomplete="new-password" required></label>
    </section>
    <div class="form-actions">
        <button class="button button--primary" type="submit">Change Password</button>
    </div>
</form>

<h2 class="group-title">API Tokens</h2>
<section class="group">
    <?php if ($newToken): ?>
        <div class="row row--link">
            <div class="row__main">
                <span class="row__title">New token</span>
                <code class="row__code" id="new-token"><?= e($newToken) ?></code>
            </div>
            <button class="button" type="button" data-copy="#new-token">Copy</button>
        </div>
    <?php endif; ?>
    <?php foreach (api_tokens() as $token): ?>
        <div class="row">
            <div class="row__main">
                <span class="row__title"><?= e($token['name']) ?></span>
                <span class="row__meta">
                    <span>Created <?= e(format_date($token['created_at'])) ?></span>
                    <span><?= $token['last_used_at'] ? 'Last used ' . e(format_date($token['last_used_at'])) : 'Never used' ?></span>
                </span>
            </div>
            <form method="post" data-confirm="Revoke “<?= e($token['name']) ?>”? Scripts using it will stop working.">
                <?= csrf_field() ?>
                <input type="hidden" name="token_id" value="<?= (int) $token['id'] ?>">
                <button class="button button--destructive" name="token_action" value="revoke">Revoke</button>
            </form>
        </div>
    <?php endforeach; ?>
    <form class="row" method="post">
        <?= csrf_field() ?>
        <input name="token_name" placeholder="Token name, e.g. MacBook release script" aria-label="Token name" maxlength="60">
        <button class="button" name="token_action" value="create">Create Token</button>
    </form>
</section>
<p class="group-footnote">Used by <code>Scripts/release.sh</code> to upload builds as drafts. Put it in <code>Scripts/web.env</code>.</p>

<h2 class="group-title">Server</h2>
<section class="group">
    <div class="row row--field"><span>PHP</span><span class="muted"><?= e(PHP_VERSION) ?></span></div>
    <div class="row row--field"><span>Upload limit</span><span class="muted"><?= e(format_bytes(max_upload_bytes())) ?></span></div>
    <div class="row row--field"><span>Releases folder</span><code class="row__code"><?= e(releases_dir()) ?></code></div>
</section>
<?php admin_footer();
