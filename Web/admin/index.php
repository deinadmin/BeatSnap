<?php
declare(strict_types=1);

require dirname(__DIR__) . '/includes/bootstrap.php';
require dirname(__DIR__) . '/includes/admin_layout.php';

$admin = require_admin();
$releases = releases_all();
$latest = release_latest();
$totalDownloads = array_sum(array_map(fn ($r) => (int) $r['downloads'], $releases));
$published = count(array_filter($releases, fn ($r) => (bool) $r['is_published']));
$latestUrl = base_url() . '/download.php';

admin_header('Releases', $admin, 'releases');
?>
<div class="page-head">
    <div>
        <h1>Releases</h1>
        <p class="muted">The download button always serves the highest published version.</p>
    </div>
    <a class="button button--primary" href="release.php">New Release</a>
</div>

<section class="stats">
    <div class="stat">
        <span class="stat__label">Live version</span>
        <span class="stat__value"><?= $latest ? e($latest['version']) : '—' ?></span>
        <span class="stat__detail"><?= $latest ? e(format_date($latest['released_at'])) : 'Nothing published yet' ?></span>
    </div>
    <div class="stat">
        <span class="stat__label">Downloads</span>
        <span class="stat__value"><?= number_format($totalDownloads) ?></span>
        <span class="stat__detail">Across all versions</span>
    </div>
    <div class="stat">
        <span class="stat__label">Releases</span>
        <span class="stat__value"><?= count($releases) ?></span>
        <span class="stat__detail"><?= $published ?> published · <?= count($releases) - $published ?> draft</span>
    </div>
</section>

<section class="group">
    <div class="row row--link">
        <div class="row__main">
            <span class="row__title">Latest download link</span>
            <code class="row__code" id="latest-url"><?= e($latestUrl) ?></code>
        </div>
        <button class="button" type="button" data-copy="#latest-url">Copy</button>
    </div>
</section>

<?php if (!$releases): ?>
    <section class="empty">
        <h2>No releases yet</h2>
        <p class="muted">Upload a build of <?= e(config('site_name')) ?> to turn on the download button.</p>
        <a class="button button--primary" href="release.php">New Release</a>
    </section>
<?php else: ?>
    <section class="group">
        <?php foreach ($releases as $release):
            $isLatest = $latest && (int) $latest['id'] === (int) $release['id'];
            $hasFile = release_is_downloadable($release);
            $source = release_local_path($release) ? format_bytes((int) $release['file_size']) : ($release['external_url'] ? 'External link' : 'No file');
            ?>
            <article class="row">
                <div class="row__main">
                    <div class="row__title">
                        <a href="release.php?id=<?= (int) $release['id'] ?>">Version <?= e($release['version']) ?></a>
                        <?php if ($release['build'] !== ''): ?><span class="muted">(<?= e($release['build']) ?>)</span><?php endif; ?>
                        <?php if ($isLatest): ?><span class="badge badge--blue">Live</span><?php endif; ?>
                        <?php if (!$release['is_published']): ?><span class="badge">Draft</span><?php endif; ?>
                        <?php if (!$hasFile): ?><span class="badge badge--red">Missing file</span><?php endif; ?>
                    </div>
                    <div class="row__meta">
                        <span><?= e(format_date($release['released_at'])) ?></span>
                        <span><?= e($source) ?></span>
                        <span><?= number_format((int) $release['downloads']) ?> <?= (int) $release['downloads'] === 1 ? 'download' : 'downloads' ?></span>
                    </div>
                </div>
                <div class="row__actions">
                    <?php if ($hasFile): ?>
                        <a class="button button--plain" href="../download.php?id=<?= (int) $release['id'] ?>">Download</a>
                    <?php endif; ?>
                    <form method="post" action="action.php">
                        <?= csrf_field() ?>
                        <input type="hidden" name="id" value="<?= (int) $release['id'] ?>">
                        <?php if ($release['is_published']): ?>
                            <button class="button" name="action" value="unpublish">Unpublish</button>
                        <?php else: ?>
                            <button class="button" name="action" value="publish"<?= $hasFile ? '' : ' disabled title="Attach a file first"' ?>>Publish</button>
                        <?php endif; ?>
                    </form>
                    <a class="button" href="release.php?id=<?= (int) $release['id'] ?>">Edit</a>
                </div>
            </article>
        <?php endforeach; ?>
    </section>
<?php endif; ?>
<?php admin_footer();
