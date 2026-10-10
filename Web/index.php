<?php
declare(strict_types=1);

require __DIR__ . '/includes/bootstrap.php';

try {
    $latest = release_latest();
} catch (Throwable $error) {
    error_log('BeatSnap landing: ' . $error->getMessage());
    $latest = null;
}
$isAdmin = viewer_is_admin();
$site = config('site_name');
$purchaseUrl = (string) config('purchase_url');
$contact = (string) config('contact_email');

$downloadMeta = $latest
    ? implode(' · ', array_filter([
        'Version ' . $latest['version'],
        release_local_path($latest) ? format_bytes((int) $latest['file_size']) : null,
        'macOS ' . $latest['min_os'] . ' or later',
    ]))
    : 'Coming soon';

/**
 * Screenshot slot. Drop PNGs into assets/img/screenshots/ (exported at 2x, with the
 * transparent shadow CleanShot or ⌘⇧4-Space produce). Missing images render nothing
 * for visitors and a labelled placeholder for signed-in admins.
 */
function screenshot(string $file, string $alt, bool $isAdmin, string $class = '', int $displayWidth = 0): string
{
    $path = __DIR__ . '/assets/img/screenshots/' . $file;
    if (is_file($path) && ($size = getimagesize($path))) {
        $width = $displayWidth ?: (int) round($size[0] / 2);
        $height = (int) round($size[1] * $width / $size[0]);
        return sprintf('<img class="shot %s" src="%s" width="%d" height="%d" alt="%s" decoding="async"%s>',
            e($class), e(asset('assets/img/screenshots/' . $file)), $width, $height, e($alt),
            str_contains($class, 'shot--hero') ? ' fetchpriority="high"' : ' loading="lazy"');
    }
    if (!$isAdmin) {
        return '';
    }
    return sprintf('<div class="shot shot--placeholder %s"><span>Screenshot slot</span><code>assets/img/screenshots/%s</code><small>%s</small></div>',
        e($class), e($file), e($alt));
}

$gallery = [
    ['editor.png', 'Editing the BPM and key of a beat', 'Fix anything', 'Right-click any beat to rename it or adjust its tempo and key.'],
    ['menubar.png', 'BeatSnap in the macOS menu bar', 'Always there', 'One click in the menu bar — or one shortcut — and your beats are back.'],
    ['daw.png', 'Dragging a beat from BeatSnap into a DAW', 'Straight to the session', 'Drop beats onto any track, in any DAW that takes audio.'],
];
$galleryHtml = '';
foreach ($gallery as [$file, $alt, $title, $text]) {
    if ($img = screenshot($file, $alt, $isAdmin)) {
        $galleryHtml .= '<figure class="gallery__item" data-reveal>' . $img
            . '<figcaption><strong>' . e($title) . '</strong> ' . e($text) . '</figcaption></figure>';
    }
}

$downloadIcon = '<svg class="button__icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2v8.5M4.5 7 8 10.5 11.5 7M3 13.5h10" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>';
?>
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <title><?= e($site) ?> — Paste a link. Get the beat.</title>
    <meta name="description" content="BeatSnap is a menu bar app for Mac that turns YouTube, Google Drive and Dropbox links into audio files, detects BPM and key automatically, and lets you drag beats straight into your DAW.">
    <meta name="theme-color" content="#ffffff">
    <meta property="og:type" content="website">
    <meta property="og:title" content="<?= e($site) ?> — Paste a link. Get the beat.">
    <meta property="og:description" content="Download beats from YouTube, Google Drive and Dropbox with BPM and key already detected. Drag them straight into your DAW.">
    <meta property="og:image" content="<?= e(base_url() . '/assets/img/app-icon.png') ?>">
    <link rel="icon" type="image/png" href="<?= e(asset('assets/img/favicon.png')) ?>">
    <link rel="apple-touch-icon" href="<?= e(asset('assets/img/apple-touch-icon.png')) ?>">
    <link rel="stylesheet" href="<?= e(asset('assets/css/site.css')) ?>">
    <script>document.documentElement.classList.add('js')</script>
    <script src="<?= e(asset('assets/js/site.js')) ?>" defer></script>
</head>
<body>

<header class="nav">
    <div class="nav__inner">
        <a class="nav__brand" href="#top">
            <img src="<?= e(asset('assets/img/favicon.png')) ?>" width="22" height="22" alt="">
            <span><?= e($site) ?></span>
        </a>
        <nav class="nav__links" aria-label="Sections">
            <a href="#links">Downloads</a>
            <a href="#analysis">BPM &amp; Key</a>
            <a href="#daw">Drag &amp; Drop</a>
            <a href="#shortcut">Shortcut</a>
        </nav>
        <a class="button button--small" href="download.php"><?= $latest ? 'Download' : 'Coming Soon' ?></a>
    </div>
</header>

<main id="top">

    <!-- Hero -->
    <section class="hero">
        <div class="hero__copy">
            <img class="hero__icon" src="<?= e(asset('assets/img/app-icon.png')) ?>" width="112" height="112" alt="<?= e($site) ?> app icon">
            <h1 class="hero__title">Paste a link.<br>Get the beat.</h1>
            <p class="hero__lede">
                BeatSnap turns links into audio files —
                with BPM and key already detected — ready to drag straight into your DAW.
            </p>
            <div class="hero__actions">
                <a class="button button--large" href="download.php"><?= $downloadIcon ?> <?= $latest ? 'Download for Mac' : 'Coming Soon' ?></a>
                <a class="link-arrow" href="#links">See how it works</a>
            </div>
            <p class="hero__meta"><?= e($downloadMeta) ?><?= $latest ? ' · Free to try' : '' ?></p>
        </div>

        <div class="hero__stage">
            <div class="hero__glow" aria-hidden="true"></div>
            <?= screenshot('library.png', 'The BeatSnap window showing a library of beats, each tagged with BPM and key', $isAdmin, 'shot--hero', 460) ?>
            <div class="float float--left" aria-hidden="true">
                <span class="kbd-inline">⌃</span><span class="kbd-inline">⌥</span><span class="kbd-inline">⇧</span><span class="kbd-inline">⌘</span><span class="kbd-inline">B</span>
                <span class="float__label">Show / hide</span>
            </div>
            <div class="float float--right" aria-hidden="true">
                <span class="pill pill--bpm">140 BPM</span><span class="pill pill--key">F# minor</span>
                <span class="float__label">Detected</span>
            </div>
        </div>
    </section>

    <!-- Link sources -->
    <section class="section" id="links">
        <div class="section__head" data-reveal>
            <p class="eyebrow eyebrow--blue">Downloads</p>
            <h2>Any link. One paste.</h2>
            <p class="section__lede">
                Copy a link from wherever the beat lives, paste it into BeatSnap, and it lands in
                your beats folder as an audio file. No converter sites, no pop-ups, no detours.
            </p>
        </div>

        <div class="paste-demo" data-reveal data-paste-demo>
            <div class="mini-window">
                <div class="mini-window__bar">
                    <div class="url-field"><span class="url-field__text" data-url>youtube.com/watch?v=Jx8f2kQ</span><span class="url-field__caret"></span></div>
                    <span class="mini-button" data-go>Download</span>
                </div>
                <div class="mini-window__rows" data-rows>
                    <div class="beat-row" data-result>
                        <span class="tile">♪</span>
                        <span class="beat-row__body">
                            <span class="beat-row__title" data-title>midnight drive (prod. nova)</span>
                            <span class="beat-row__tags"><span class="pill pill--bpm" data-bpm>140 BPM</span><span class="pill pill--key" data-key>F# minor</span><span class="beat-row__time" data-time>2:48</span></span>
                        </span>
                    </div>
                    <div class="beat-row beat-row--dim">
                        <span class="tile">♪</span>
                        <span class="beat-row__body">
                            <span class="beat-row__title">late checkout</span>
                            <span class="beat-row__tags"><span class="pill pill--bpm">92 BPM</span><span class="pill pill--key">C# major</span><span class="beat-row__time">3:12</span></span>
                        </span>
                    </div>
                </div>
            </div>
        </div>

        <ul class="sources" data-reveal>
            <li class="source" data-source="youtube">
                <svg viewBox="0 0 32 32" aria-hidden="true"><rect x="2" y="7" width="28" height="18" rx="6" fill="#ff0033"/><path d="M13.5 11.8v8.4l7-4.2z" fill="#fff"/></svg>
                <span>YouTube</span>
            </li>
            <li class="source" data-source="drive">
                <svg viewBox="0 0 32 32" aria-hidden="true"><path d="M11.3 5h9.4l9.3 16h-9.4z" fill="#ffc107"/><path d="M11.3 5 2 21l4.7 8 9.3-16z" fill="#0f9d58"/><path d="M6.7 29h18.6l4.7-8H11.4z" fill="#4285f4"/></svg>
                <span>Google Drive</span>
            </li>
            <li class="source" data-source="dropbox">
                <svg viewBox="0 0 32 32" aria-hidden="true" fill="#0061ff"><path d="m9.5 4-7 4.5 7 4.5 6.5-4.5zM22.5 4 16 8.5l6.5 4.5 7-4.5zM2.5 17.5l7 4.5 6.5-4.5-6.5-4.5zM22.5 13 16 17.5l6.5 4.5 7-4.5zM9.5 23.5 16 28l6.5-4.5L16 19z"/></svg>
                <span>Dropbox</span>
            </li>
            <li class="source" data-source="direct">
                <svg viewBox="0 0 32 32" aria-hidden="true" fill="none" stroke="#6e6e73" stroke-width="2.4" stroke-linecap="round"><path d="M13.5 18.5a5 5 0 0 0 7 0l4-4a5 5 0 0 0-7-7l-1.2 1.2"/><path d="M18.5 13.5a5 5 0 0 0-7 0l-4 4a5 5 0 0 0 7 7l1.2-1.2"/></svg>
                <span>Audio links</span>
            </li>
            <li class="source" data-source="files">
                <svg viewBox="0 0 32 32" aria-hidden="true"><path d="M3 9a3 3 0 0 1 3-3h6.2l3 3H26a3 3 0 0 1 3 3v12a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3z" fill="#5ac8fa"/><path d="M3 13h26v11a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3z" fill="#1a9cf0"/></svg>
                <span>Files from Finder</span>
            </li>
        </ul>
        <p class="footnote" data-reveal>Works with public share links. Already have the file? Drop it on the window, or copy it in Finder and paste.</p>
    </section>

    <!-- BPM & key -->
    <section class="section section--tint" id="analysis">
        <div class="split">
            <div class="split__copy" data-reveal>
                <p class="eyebrow"><span class="eyebrow__bpm">BPM</span> <span class="eyebrow__and">&amp;</span> <span class="eyebrow__key">Key</span></p>
                <h2>Know the tempo and key before you hit play.</h2>
                <p class="section__lede">
                    Every beat is analysed the moment it arrives. Tempo and musical key show up right
                    next to the title — and in the file name, so they travel with the beat into every project.
                </p>
                <ul class="checklist">
                    <li>Detected automatically, every time</li>
                    <li>Analysed on your Mac — nothing is uploaded</li>
                    <li>Off by a hair? Correct BPM and key in two clicks</li>
                </ul>
            </div>
            <div class="analysis-demo" data-reveal data-analysis>
                <div class="panel">
                    <?php foreach ([
                        ['sunset on melrose', '128 BPM', 'D major', '2:01'],
                        ['vento — italian sample', '133 BPM', 'A minor', '3:40'],
                        ['bathroom mirror', '101 BPM', 'C minor', '3:32'],
                        ['slay (jazz flip)', '164 BPM', 'E major', '2:35'],
                    ] as $i => [$title, $bpm, $key, $time]): ?>
                        <div class="beat-row" style="--i: <?= $i ?>">
                            <span class="tile">♪</span>
                            <span class="beat-row__body">
                                <span class="beat-row__title"><?= e($title) ?></span>
                                <span class="beat-row__tags">
                                    <span class="pill pill--bpm pill--resolve"><?= e($bpm) ?></span>
                                    <span class="pill pill--key pill--resolve"><?= e($key) ?></span>
                                    <span class="beat-row__time"><?= e($time) ?></span>
                                </span>
                            </span>
                        </div>
                    <?php endforeach; ?>
                </div>
                <div class="filename">
                    <svg viewBox="0 0 20 24" aria-hidden="true"><path d="M3 1h9l6 6v14a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V3a2 2 0 0 1 2-2z" fill="#fff" stroke="#c7c7cc"/><path d="M12 1v6h6" fill="none" stroke="#c7c7cc"/><path d="M7 17v-6l6-1.2V16" fill="none" stroke="#0a85ff" stroke-width="1.4"/><circle cx="5.8" cy="17" r="1.6" fill="#0a85ff"/><circle cx="11.8" cy="16" r="1.6" fill="#0a85ff"/></svg>
                    <span>sunset on melrose <b>[128BPM Dmaj]</b>.mp3</span>
                </div>
            </div>
        </div>
    </section>

    <!-- Drag into DAW -->
    <section class="section" id="daw">
        <div class="section__head" data-reveal>
            <p class="eyebrow eyebrow--orange">Drag &amp; Drop</p>
            <h2>Straight into your session.</h2>
            <p class="section__lede">
                Grab any beat and drop it onto a track. It’s a real audio file, so it works wherever
                audio does — Logic Pro, Ableton Live, FL Studio, Pro Tools, Cubase, Studio One and more.
            </p>
        </div>

        <div class="daw" data-reveal aria-hidden="true">
            <div class="daw__window">
                <div class="daw__titlebar"><span class="lights"><i></i><i></i><i></i></span><span>My Song — Arrangement</span></div>
                <div class="daw__ruler"><?php for ($bar = 1; $bar <= 9; $bar++): ?><span><?= $bar ?></span><?php endfor; ?></div>
                <div class="daw__tracks">
                    <div class="track"><span class="track__head"><i style="--c:#ff9f0a"></i>Drums</span><span class="track__lane"><span class="clip" style="--c:#ff9f0a; left: 2cqw; width: 26cqw"><span class="wave"></span></span><span class="clip" style="--c:#ff9f0a; left: 29cqw; width: 26cqw"><span class="wave"></span></span></span></div>
                    <div class="track"><span class="track__head"><i style="--c:#30d158"></i>Bass</span><span class="track__lane"><span class="clip" style="--c:#30d158; left: 15.5cqw; width: 39.5cqw"><span class="wave"></span></span></span></div>
                    <div class="track track--target"><span class="track__head"><i style="--c:#0a85ff"></i>Beat</span><span class="track__lane"><span class="clip clip--drop" style="--c:#0a85ff; left: 2cqw; width: 40cqw"><em>sunset on melrose [128BPM Dmaj]</em><span class="wave"></span></span></span></div>
                    <div class="track"><span class="track__head"><i style="--c:#bf5af2"></i>Vocals</span><span class="track__lane"></span></div>
                </div>
            </div>
            <div class="daw__panel">
                <div class="daw__panel-bar"><span class="url-field url-field--mini">Paste an audio or YouTube link…</span></div>
                <div class="beat-row beat-row--mini beat-row--source">
                    <span class="tile">♪</span>
                    <span class="beat-row__body"><span class="beat-row__title">sunset on melrose</span><span class="beat-row__tags"><span class="pill pill--bpm">128 BPM</span><span class="pill pill--key">D major</span></span></span>
                </div>
                <div class="beat-row beat-row--mini">
                    <span class="tile">♪</span>
                    <span class="beat-row__body"><span class="beat-row__title">vento — italian sample</span><span class="beat-row__tags"><span class="pill pill--bpm">133 BPM</span><span class="pill pill--key">A minor</span></span></span>
                </div>
                <div class="beat-row beat-row--mini">
                    <span class="tile">♪</span>
                    <span class="beat-row__body"><span class="beat-row__title">bathroom mirror</span><span class="beat-row__tags"><span class="pill pill--bpm">101 BPM</span><span class="pill pill--key">C minor</span></span></span>
                </div>
                <div class="beat-row beat-row--mini">
                    <span class="tile">♪</span>
                    <span class="beat-row__body"><span class="beat-row__title">slay (jazz flip)</span><span class="beat-row__tags"><span class="pill pill--bpm">164 BPM</span><span class="pill pill--key">E major</span></span></span>
                </div>
            </div>
            <div class="daw__ghost">
                <div class="beat-row beat-row--mini">
                    <span class="tile">♪</span>
                    <span class="beat-row__body"><span class="beat-row__title">sunset on melrose</span><span class="beat-row__tags"><span class="pill pill--bpm">128 BPM</span><span class="pill pill--key">D major</span></span></span>
                </div>
            </div>
            <svg class="daw__cursor" viewBox="0 0 20 24"><path d="M2 1.5v18l4.6-4.3 3 7 3.2-1.4-3-6.8H16z" fill="#000" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg>
        </div>

        <div class="trio" data-reveal>
            <div><h3>Preview first</h3><p>Play and scrub any beat right in the list before it goes anywhere.</p></div>
            <div><h3>Real files</h3><p>Everything is saved as ordinary audio in a folder you choose. Show in Finder anytime.</p></div>
            <div><h3>Original quality</h3><p>Files from Drive, Dropbox and audio links arrive exactly as they were shared.</p></div>
        </div>
    </section>

    <!-- Shortcut -->
    <section class="section section--dark" id="shortcut">
        <div class="section__head" data-reveal>
            <p class="eyebrow eyebrow--glow">Shortcut</p>
            <h2>Always one keystroke away.</h2>
            <p class="section__lede">
                Show and hide BeatSnap from any app — mid-session, in full screen, wherever you are.
                Prefer a different combination? Set your own.
            </p>
        </div>
        <div class="keys" data-reveal data-keys>
            <span class="key"><b>⌃</b><small>control</small></span>
            <span class="key"><b>⌥</b><small>option</small></span>
            <span class="key"><b>⇧</b><small>shift</small></span>
            <span class="key key--wide"><b>⌘</b><small>command</small></span>
            <span class="key key--letter"><b>B</b></span>
        </div>
        <div class="menubar" data-reveal aria-hidden="true">
            <span class="menubar__item menubar__item--dim">Wi‑Fi</span>
            <span class="menubar__icon">
                <svg viewBox="0 0 20 20"><path d="M8 15.5V4.2l8-1.7v8.8" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/><circle cx="5.6" cy="15.5" r="2.4" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="m13.6 12.8 2.4 2.6 2.4-2.6" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>
            </span>
            <span class="menubar__item">Thu 10:04</span>
        </div>
        <p class="footnote footnote--dark" data-reveal>Lives quietly in your menu bar. Never clutters your Dock.</p>
    </section>

    <!-- Details -->
    <section class="section section--tint" id="details">
        <div class="section__head" data-reveal>
            <p class="eyebrow eyebrow--blue">And the details</p>
            <h2>Small things, done right.</h2>
        </div>
        <div class="grid">
            <article class="card card--wide" data-reveal>
                <div>
                    <h3>Clean, calm, unmistakably Mac.</h3>
                    <p>One compact window: your beats, their tempo, their key. No clutter, no setup screens — it feels like it shipped with macOS.</p>
                </div>
                <div class="card__visual">
                    <div class="beat-row"><span class="tile">♪</span><span class="beat-row__body"><span class="beat-row__title">218_128BPM</span><span class="beat-row__tags"><span class="pill pill--bpm">128 BPM</span><span class="pill pill--key">D major</span><span class="beat-row__time">2:01</span></span></span></div>
                    <div class="beat-row beat-row--playing"><span class="tile tile--play">▶︎</span><span class="beat-row__body"><span class="beat-row__title">club &amp; 2000s</span><span class="progress-line"><i></i></span></span></div>
                </div>
            </article>
            <article class="card" data-reveal>
                <svg class="card__icon" viewBox="0 0 28 28"><circle cx="14" cy="14" r="11" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="m11.5 9.5 7 4.5-7 4.5z" fill="currentColor"/></svg>
                <h3>Preview &amp; scrub</h3>
                <p>Listen to any beat and scrub through it without leaving the list.</p>
            </article>
            <article class="card" data-reveal>
                <svg class="card__icon" viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M5 8h18M5 14h18M5 20h11"/><path d="m20 18 3 3-3 3" stroke-linejoin="round"/></svg>
                <h3>A queue that keeps going</h3>
                <p>Paste one link after another. BeatSnap works through them in order — even with the window closed.</p>
            </article>
            <article class="card" data-reveal>
                <svg class="card__icon" viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14 4v13M9 12l5 5 5-5"/><path d="M4 18v3a3 3 0 0 0 3 3h14a3 3 0 0 0 3-3v-3"/></svg>
                <h3>Drop or paste files</h3>
                <p>Drag audio onto the window, or copy it in Finder and press ⌘V. It’s analysed like everything else.</p>
            </article>
            <article class="card" data-reveal>
                <svg class="card__icon" viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M17.5 5.5l5 5L10 23H5v-5z"/><path d="m15 8 5 5"/></svg>
                <h3>Rename &amp; retag</h3>
                <p>Right-click any beat to rename it, correct its BPM or key, or show it in Finder.</p>
            </article>
            <article class="card" data-reveal>
                <svg class="card__icon" viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M14 3.5 5 7v6.5c0 5.4 3.8 9.4 9 11 5.2-1.6 9-5.6 9-11V7z"/><path d="m10 14 3 3 5-6" stroke-linecap="round"/></svg>
                <h3>Private by design</h3>
                <p>Tempo and key are worked out entirely on your Mac. Your music never leaves it.</p>
            </article>
            <article class="card" data-reveal>
                <svg class="card__icon" viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M4 9.5 14 4l10 5.5v9L14 24 4 18.5z"/><path d="M4 9.5 14 15l10-5.5M14 15v9"/></svg>
                <h3>Nothing else to install</h3>
                <p>Everything BeatSnap needs comes in the box. Download it, open it, paste a link.</p>
            </article>
            <article class="card" data-reveal>
                <svg class="card__icon" viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 21h20"/><path d="M7 21V12M12 21V7M17 21v-6M22 21V9"/></svg>
                <h3>Tidy file names</h3>
                <p>Re-analysing a beat updates its tag instead of piling on another one. Your folder stays tidy.</p>
            </article>
        </div>
    </section>

    <?php if ($galleryHtml !== ''): ?>
    <!-- Gallery: add editor.png, menubar.png, daw.png to assets/img/screenshots/ -->
    <section class="section" id="gallery">
        <div class="section__head" data-reveal>
            <p class="eyebrow eyebrow--blue">A closer look</p>
            <h2>See it in action.</h2>
        </div>
        <div class="gallery"><?= $galleryHtml ?></div>
    </section>
    <?php endif; ?>

    <!-- Download -->
    <section class="section cta" id="download">
        <div class="cta__inner" data-reveal>
            <img class="cta__icon" src="<?= e(asset('assets/img/app-icon.png')) ?>" width="128" height="128" alt="">
            <h2>Get <?= e($site) ?>.</h2>
            <p class="section__lede">Free to try. Unlock your whole library and unlimited downloads with a license key.</p>
            <div class="hero__actions">
                <a class="button button--large" href="download.php"><?= $downloadIcon ?> <?= $latest ? 'Download for Mac' : 'Coming Soon' ?></a>
                <?php if ($purchaseUrl !== ''): ?>
                    <a class="link-arrow" href="<?= e($purchaseUrl) ?>">Buy a license</a>
                <?php endif; ?>
            </div>
            <p class="hero__meta"><?= e($downloadMeta) ?><?= $latest ? ' · Apple silicon' : '' ?></p>

            <?php if ($latest && trim((string) $latest['notes']) !== ''): ?>
                <details class="notes">
                    <summary>What’s new in <?= e($latest['version']) ?></summary>
                    <div class="notes__body">
                        <p class="notes__date"><?= e(format_date($latest['released_at'])) ?></p>
                        <?= render_notes((string) $latest['notes']) ?>
                    </div>
                </details>
            <?php endif; ?>
        </div>
    </section>
</main>

<footer class="footer">
    <div class="footer__inner">
        <p>© <?= date('Y') ?> <?= e(config('author')) ?>. <?= e($site) ?> is not affiliated with YouTube, Google or Dropbox.</p>
        <nav>
            <a href="download.php">Download</a>
            <?php if ($contact !== ''): ?><a href="mailto:<?= e($contact) ?>">Contact</a><?php endif; ?>
            <?php if ($isAdmin): ?><a href="admin/">Admin</a><?php endif; ?>
        </nav>
    </div>
</footer>

</body>
</html>
