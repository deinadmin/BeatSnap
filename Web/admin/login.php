<?php
declare(strict_types=1);

require dirname(__DIR__) . '/includes/bootstrap.php';
require dirname(__DIR__) . '/includes/admin_layout.php';

start_session();
if (admin_count() === 0) {
    redirect('setup.php');
}
if (current_admin()) {
    redirect('index.php');
}

$error = null;
$username = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $username = trim((string) ($_POST['username'] ?? ''));
    if (!csrf_valid()) {
        $error = 'Your session expired. Please try again.';
    } else {
        $error = attempt_login($username, (string) ($_POST['password'] ?? ''));
        if ($error === null) {
            redirect('index.php');
        }
    }
}

header('X-Frame-Options: DENY');
admin_header('Sign In');
?>
<form class="auth-card" method="post" autocomplete="on">
    <img class="auth-card__icon" src="<?= e(asset('assets/img/app-icon.png', '../')) ?>" width="72" height="72" alt="">
    <h1>Sign in to <?= e(config('site_name')) ?></h1>
    <?php if ($error) admin_error($error); ?>
    <?= csrf_field() ?>
    <div style="margin-top: 1rem;" class="field-group">
        <label class="field">
            <span class="sr-only">Username</span>
            <input name="username" value="<?= e($username) ?>" placeholder="Username" autocomplete="username" required autofocus>
        </label>
        <label class="field">
            <span class="sr-only">Password</span>
            <input type="password" name="password" placeholder="Password" autocomplete="current-password" required>
        </label>
    </div>
    <button class="button button--primary button--wide" type="submit">Sign In</button>
</form>
<?php admin_footer();
