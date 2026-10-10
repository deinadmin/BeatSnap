<?php
declare(strict_types=1);

require dirname(__DIR__) . '/includes/bootstrap.php';

require_admin();

if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !csrf_valid()) {
    flash('Your session expired. Please try again.', 'error');
    redirect('index.php');
}

$release = release_find((int) ($_POST['id'] ?? 0));
if (!$release) {
    flash('That release no longer exists.', 'error');
    redirect('index.php');
}

$version = $release['version'];
switch ($_POST['action'] ?? '') {
    case 'publish':
        if (!release_is_downloadable($release)) {
            flash("Version {$version} has no file to download yet.", 'error');
            break;
        }
        release_set_published((int) $release['id'], true);
        $latest = release_latest();
        flash($latest && (int) $latest['id'] === (int) $release['id']
            ? "Version {$version} is live. The download button now serves it."
            : "Version {$version} is published. A newer version is still the live download.");
        break;

    case 'unpublish':
        release_set_published((int) $release['id'], false);
        flash("Version {$version} is now a draft.");
        break;

    case 'delete':
        release_delete((int) $release['id'], !empty($_POST['delete_file']));
        flash("Version {$version} was deleted.");
        break;

    default:
        flash('Unknown action.', 'error');
}

redirect('index.php');
