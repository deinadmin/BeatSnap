<?php
declare(strict_types=1);

require dirname(__DIR__) . '/includes/bootstrap.php';
require dirname(__DIR__) . '/includes/admin_layout.php';

$admin = require_admin();

$id = isset($_GET['id']) ? (int) $_GET['id'] : null;
$existing = $id ? release_find($id) : null;
if ($id && !$existing) {
    flash('That release no longer exists.', 'error');
    redirect('index.php');
}

$isAjax = ($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '') === 'fetch';
$form = $existing ?? [
    'version'      => '',
    'build'        => '',
    'notes'        => '',
    'min_os'       => '26.0',
    'released_at'  => date('Y-m-d'),
    'is_published' => 1,
    'file_name'    => null,
    'external_url' => null,
];
$form['released_at'] = substr((string) $form['released_at'], 0, 10);
$source = $existing && release_is_downloadable($existing) ? 'keep' : 'upload';
$error = null;

function is_download_url(string $url): bool
{
    return preg_match('#^https?://#i', $url) === 1 && filter_var($url, FILTER_VALIDATE_URL) !== false;
}

function fail(string $message): void
{
    global $isAjax, $error;
    if ($isAjax) {
        http_response_code(422);
        header('Content-Type: application/json');
        echo json_encode(['error' => $message]);
        exit;
    }
    $error = $message;
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (empty($_POST) && (int) ($_SERVER['CONTENT_LENGTH'] ?? 0) > 0) {
        fail('The file is larger than this server’s upload limit (' . format_bytes(max_upload_bytes())
            . '). Upload it to the releases folder over SFTP and choose “File on Server”.');
    } elseif (!csrf_valid()) {
        fail('Your session expired. Reload the page and try again.');
    } else {
        $form = array_merge($form, [
            'version'      => trim((string) ($_POST['version'] ?? '')),
            'build'        => trim((string) ($_POST['build'] ?? '')),
            'notes'        => trim(str_replace("\r\n", "\n", (string) ($_POST['notes'] ?? ''))),
            'min_os'       => trim((string) ($_POST['min_os'] ?? '')),
            'released_at'  => trim((string) ($_POST['released_at'] ?? '')),
            'is_published' => empty($_POST['is_published']) ? 0 : 1,
        ]);
        $source = (string) ($_POST['source'] ?? 'keep');
        $other = $form['version'] !== '' ? release_find_by_version($form['version']) : null;
        $file = $_FILES['file'] ?? null;
        $serverFiles = array_column(unattached_release_files(), 'name');
        $extensions = config('allowed_extensions');

        if ($message = release_fields_error($form)) {
            fail($message);
        } elseif ($other && (int) $other['id'] !== (int) $id) {
            fail("Version {$form['version']} already exists.");
        } elseif ($source === 'upload' && (!$file || $file['error'] === UPLOAD_ERR_NO_FILE)) {
            fail('Choose a file to upload.');
        } elseif ($source === 'upload' && in_array($file['error'], [UPLOAD_ERR_INI_SIZE, UPLOAD_ERR_FORM_SIZE], true)) {
            fail('The file is larger than this server’s upload limit (' . format_bytes(max_upload_bytes())
                . '). Upload it over SFTP and choose “File on Server”.');
        } elseif ($source === 'upload' && $file['error'] !== UPLOAD_ERR_OK) {
            fail('The upload didn’t complete (error ' . (int) $file['error'] . '). Please try again.');
        } elseif ($source === 'upload' && !in_array(strtolower(pathinfo($file['name'], PATHINFO_EXTENSION)), $extensions, true)) {
            fail('Upload a ' . implode(', ', array_map(fn ($x) => ".{$x}", $extensions)) . ' file.');
        } elseif ($source === 'server' && !in_array($_POST['server_file'] ?? '', $serverFiles, true)) {
            fail('Choose a file from the releases folder.');
        } elseif ($source === 'url' && !is_download_url((string) ($_POST['external_url'] ?? ''))) {
            fail('Enter a full download link starting with https://.');
        } elseif ($source === 'keep' && !$existing) {
            fail('Choose a file for this release.');
        }

        if ($error === null) {
            $fields = $form;
            try {
                if ($source === 'upload') {
                    $extension = strtolower(pathinfo($file['name'], PATHINFO_EXTENSION));
                    $name = release_target_name($form['version'], $extension, $id);
                    $target = releases_dir() . '/' . $name;
                    if (!move_uploaded_file($file['tmp_name'], $target)) {
                        throw new RuntimeException('The uploaded file couldn’t be saved. Check that the storage folder is writable.');
                    }
                    $fields['file_name'] = $name;
                } elseif ($source === 'server') {
                    $fields['file_name'] = $_POST['server_file'];
                }

                if ($source === 'upload' || $source === 'server') {
                    $path = releases_dir() . '/' . $fields['file_name'];
                    $fields['external_url'] = null;
                    $fields['file_size'] = (int) filesize($path);
                    $fields['sha256'] = hash_file('sha256', $path);
                } elseif ($source === 'url') {
                    $fields['external_url'] = trim((string) $_POST['external_url']);
                    $fields['file_name'] = null;
                    $fields['file_size'] = null;
                    $fields['sha256'] = null;
                }

                if ($fields['is_published'] && !release_is_downloadable($fields)) {
                    $fields['is_published'] = 0;
                    flash("Version {$form['version']} was saved as a draft because it has no file yet.", 'error');
                }

                $savedId = release_save($fields, $id);
                $latest = release_latest();
                $isLive = $latest && (int) $latest['id'] === $savedId;
                flash($isLive
                    ? "Version {$form['version']} is saved and live."
                    : "Version {$form['version']} is saved.");

                if ($isAjax) {
                    header('Content-Type: application/json');
                    echo json_encode(['redirect' => 'index.php']);
                    exit;
                }
                redirect('index.php');
            } catch (Throwable $exception) {
                error_log('BeatSnap release save: ' . $exception->getMessage());
                fail($exception instanceof RuntimeException ? $exception->getMessage() : 'The release couldn’t be saved.');
            }
        }
    }
}

$serverFiles = unattached_release_files();
$currentFile = $existing ? (release_local_path($existing) ? $existing['file_name'] : $existing['external_url']) : null;
$title = $existing ? "Version {$existing['version']}" : 'New Release';
$checked = fn (string $value) => $source === $value ? ' checked' : '';

admin_header($title, $admin, 'releases');
?>
<div class="page-head">
    <div>
        <a class="back" href="index.php">Releases</a>
        <h1><?= e($title) ?></h1>
    </div>
</div>

<div id="form-error"><?php if ($error) admin_error($error); ?></div>

<form class="release-form" method="post" enctype="multipart/form-data" data-upload>
    <?= csrf_field() ?>

    <h2 class="group-title">Details</h2>
    <section class="group">
        <label class="row row--field">
            <span>Version</span>
            <input name="version" value="<?= e($form['version']) ?>" placeholder="1.0.0" required pattern="\d+(\.\d+){0,3}(-[0-9A-Za-z.\-]+)?" spellcheck="false">
        </label>
        <label class="row row--field">
            <span>Build</span>
            <input name="build" value="<?= e($form['build']) ?>" placeholder="Optional" spellcheck="false">
        </label>
        <label class="row row--field">
            <span>Release date</span>
            <input type="date" name="released_at" value="<?= e($form['released_at']) ?>" required>
        </label>
        <label class="row row--field">
            <span>Requires macOS</span>
            <input name="min_os" value="<?= e($form['min_os']) ?>" placeholder="26.0" required>
        </label>
    </section>

    <h2 class="group-title">File</h2>
    <section class="group source-picker">
        <div class="row">
            <div class="segmented segmented--control" role="radiogroup" aria-label="File source">
                <?php if ($existing): ?>
                    <label><input type="radio" name="source" value="keep"<?= $checked('keep') ?>><span>Current</span></label>
                <?php endif; ?>
                <label><input type="radio" name="source" value="upload"<?= $checked('upload') ?>><span>Upload</span></label>
                <label><input type="radio" name="source" value="server"<?= $checked('server') ?>><span>File on Server</span></label>
                <label><input type="radio" name="source" value="url"<?= $checked('url') ?>><span>Link</span></label>
            </div>
        </div>

        <?php if ($existing): ?>
            <div class="row source source--keep">
                <div class="row__main">
                    <span class="row__title"><?= $currentFile ? e($currentFile) : 'No file attached' ?></span>
                    <?php if ($existing['sha256']): ?>
                        <span class="row__meta"><span><?= e(format_bytes((int) $existing['file_size'])) ?></span><span class="mono">SHA-256 <?= e(substr($existing['sha256'], 0, 16)) ?>…</span></span>
                    <?php endif; ?>
                </div>
            </div>
        <?php endif; ?>

        <div class="row source source--upload">
            <label class="dropzone">
                <input type="file" name="file" accept="<?= e(implode(',', array_map(fn ($x) => ".{$x}", config('allowed_extensions')))) ?>">
                <span class="dropzone__title" data-file-label>Choose a .dmg, .zip or .pkg</span>
                <span class="dropzone__hint">or drop it here · up to <?= e(format_bytes(max_upload_bytes())) ?></span>
            </label>
            <div class="progress" hidden><div class="progress__bar"></div><span class="progress__label"></span></div>
        </div>

        <div class="row source source--server">
            <?php if ($serverFiles): ?>
                <select name="server_file" aria-label="File on server">
                    <?php foreach ($serverFiles as $serverFile): ?>
                        <option value="<?= e($serverFile['name']) ?>"><?= e($serverFile['name']) ?> — <?= e(format_bytes($serverFile['size'])) ?></option>
                    <?php endforeach; ?>
                </select>
            <?php else: ?>
                <p class="muted">No unattached files found. Upload builds that exceed the server’s upload limit to
                    <code><?= e(releases_dir()) ?></code> over SFTP, then reload this page.</p>
            <?php endif; ?>
        </div>

        <div class="row source source--url">
            <input type="url" name="external_url" value="<?= e((string) ($form['external_url'] ?? '')) ?>" placeholder="https://example.com/BeatSnap-1.0.0.dmg" aria-label="Download link">
        </div>
    </section>

    <h2 class="group-title">What’s New</h2>
    <section class="group">
        <textarea name="notes" rows="7" placeholder="- Faster key detection&#10;- New shortcut settings"><?= e($form['notes']) ?></textarea>
    </section>
    <p class="group-footnote">Start lines with “-” to make a list. Shown on the website next to the download button.</p>

    <section class="group">
        <label class="row row--toggle">
            <span class="row__main">
                <span class="row__title">Published</span>
                <span class="row__meta"><span>The highest published version is what the download button serves.</span></span>
            </span>
            <input type="checkbox" class="switch" name="is_published" value="1"<?= $form['is_published'] ? ' checked' : '' ?>>
        </label>
    </section>

    <div class="form-actions">
        <a class="button" href="index.php">Cancel</a>
        <button class="button button--primary" type="submit"><?= $existing ? 'Save Changes' : 'Create Release' ?></button>
    </div>
</form>

<?php if ($existing): ?>
    <h2 class="group-title">Danger Zone</h2>
    <form class="group" method="post" action="action.php" data-confirm="Delete version <?= e($existing['version']) ?>? This can’t be undone.">
        <?= csrf_field() ?>
        <input type="hidden" name="id" value="<?= (int) $existing['id'] ?>">
        <div class="row">
            <label class="check">
                <input type="checkbox" name="delete_file" value="1"<?= release_local_path($existing) ? ' checked' : ' disabled' ?>>
                <span>Also delete the file from the server</span>
            </label>
            <button class="button button--destructive" name="action" value="delete">Delete Release</button>
        </div>
    </form>
<?php endif;
admin_footer();
