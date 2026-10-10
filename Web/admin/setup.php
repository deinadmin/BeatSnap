<?php
declare(strict_types=1);

require dirname(__DIR__) . '/includes/bootstrap.php';
require dirname(__DIR__) . '/includes/admin_layout.php';

start_session();
if (admin_count() > 0) {
    redirect('login.php');
}

$setupKey = (string) config('setup_key');
$error = null;
$username = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST' && $setupKey !== '') {
    $username = trim((string) ($_POST['username'] ?? ''));
    $password = (string) ($_POST['password'] ?? '');

    if (!csrf_valid()) {
        $error = 'Your session expired. Please try again.';
    } elseif (login_locked_out(client_ip())) {
        $error = 'Too many attempts. Try again in 15 minutes.';
    } elseif (!hash_equals($setupKey, (string) ($_POST['setup_key'] ?? ''))) {
        db()->prepare('INSERT INTO login_attempts (ip, attempted_at) VALUES (?, ?)')->execute([client_ip(), time()]);
        $error = 'The setup key is incorrect.';
    } elseif (!preg_match('/^[A-Za-z0-9._\-]{3,32}$/', $username)) {
        $error = 'Use 3–32 letters, numbers, dots, dashes or underscores for the username.';
    } elseif (strlen($password) < PASSWORD_MIN_LENGTH) {
        $error = 'The password must be at least ' . PASSWORD_MIN_LENGTH . ' characters.';
    } elseif ($password !== ($_POST['password_confirm'] ?? '')) {
        $error = 'The passwords don’t match.';
    } else {
        log_in(admin_create($username, $password));
        flash('Welcome! Add your first release to enable downloads.');
        redirect('index.php');
    }
}

header('X-Frame-Options: DENY');
admin_header('Set Up');
?>
<form class="auth-card" method="post">
    <img class="auth-card__icon" src="<?= e(asset('assets/img/app-icon.png', '../')) ?>" width="72" height="72" alt="">
    <h1>Set up <?= e(config('site_name')) ?> Admin</h1>
    <?php if ($setupKey === ''): ?>
        <p class="muted">Setup is locked. Add a <code>setup_key</code> to <code>includes/config.local.php</code>, then reload this page.</p>
    <?php else: ?>
        <p class="muted">Create the administrator account.</p>
        <?php if ($error) admin_error($error); ?>
        <?= csrf_field() ?>
        <div class="field-group">
            <label class="field"><span class="sr-only">Setup key</span>
                <input type="password" name="setup_key" placeholder="Setup key" autocomplete="off" required autofocus></label>
        </div>
        <div class="field-group">
            <label class="field"><span class="sr-only">Username</span>
                <input name="username" value="<?= e($username) ?>" placeholder="Username" autocomplete="username" required></label>
            <label class="field"><span class="sr-only">Password</span>
                <input type="password" name="password" placeholder="Password (<?= PASSWORD_MIN_LENGTH ?>+ characters)" autocomplete="new-password" minlength="<?= PASSWORD_MIN_LENGTH ?>" required></label>
            <label class="field"><span class="sr-only">Confirm password</span>
                <input type="password" name="password_confirm" placeholder="Confirm password" autocomplete="new-password" required></label>
        </div>
        <button class="button button--primary button--wide" type="submit">Create Account</button>
    <?php endif; ?>
</form>
<?php admin_footer();
