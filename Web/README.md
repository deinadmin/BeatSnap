# BeatSnap website

One-page landing site plus a small PHP admin for publishing releases. No framework, no
build step, no Composer — upload the folder to any PHP host.

- `index.php` — landing page. Shows the live version, size and release notes.
- `download.php` (also `/download`) — always serves the highest published version.
  `?version=1.2.0` serves a specific published version.
- `api/latest.php` — JSON metadata for the live version (for in-app update checks).
- `appcast.php` — Sparkle update feed (newest published release that has an EdDSA signature).
  The DMG is served to Sparkle at `/downloads/BeatSnap-<version>.dmg`.
- `admin/` — releases dashboard, upload/edit/publish/delete, password change.

## Requirements

PHP 8.1+ with `pdo_sqlite` (enabled on nearly every host). Apache with `mod_rewrite`
is assumed; see below for nginx.

## Deploy

1. Upload the contents of `Web/` to your web root.
2. Copy `includes/config.local.sample.php` to `includes/config.local.php` and set
   `base_url` and a long random `setup_key` (`openssl rand -hex 24`).
3. Make `storage/` writable by PHP. If your host allows it, point `storage_path` at a
   folder outside the web root instead.
4. Visit `/admin/setup.php`, enter the setup key, and create your account. Setup locks
   itself once an admin exists; you can then blank the `setup_key`.
5. In the admin, choose **New Release** and upload the DMG.

## Publishing releases

- The download button serves the **highest published version** (compared as version
  numbers, so 1.10.0 beats 1.9.0). Drafts are never served to visitors.
- Publishing a pre-release such as `2.0.0-beta.1` makes it live for everyone. Keep betas
  as drafts and share them with the admin **Download** link instead.
- Files can come from three places:
  - **Upload** — through the browser, with a progress bar. `.user.ini` / `.htaccess` raise
    PHP's limit to 512 MB where the host allows it; the actual limit is shown in the form.
  - **File on Server** — for builds larger than the upload limit: copy the DMG into
    `storage/releases/` over SFTP and pick it from the list.
  - **Link** — an external URL (e.g. a CDN or GitHub release); `download.php` redirects to it.
- Downloads are counted per release (resumed partial downloads aren't double counted).

## Screenshots

Screenshots live in `assets/img/screenshots/`. Export them with a transparent background
and window shadow (CleanShot, or ⌘⇧4 then Space) at 2x.

| File | Where it appears |
| --- | --- |
| `library.png` | Hero, below the headline (displayed 460 pt wide) |
| `editor.png` | "See it in action" gallery — BPM/key editor or right-click menu |
| `menubar.png` | Gallery — the menu bar icon with the window open |
| `daw.png` | Gallery — dragging a beat into a DAW |

The gallery only appears once at least one of its images exists. While signed in to the
admin, the landing page shows a labelled placeholder for every missing image.

## nginx

`.htaccess` rules don't apply on nginx. Add the equivalent:

```nginx
location ~ ^/(includes|storage)/ { deny all; }
location ~ /\.(?!well-known/) { deny all; }
location = /download { rewrite ^ /download.php last; }
location ~ ^/downloads/BeatSnap-(.+)\.dmg$ { rewrite ^ /download.php?get=1&version=$1 last; }
client_max_body_size 520m;
```

## Local development

```sh
docker compose up -d --build   # http://localhost:8088, admin at /admin
docker compose logs -f         # Apache access log + PHP errors
docker compose down            # stop (data is kept)
docker compose down -v         # stop and wipe the database and uploads
```

The site folder is mounted live, so edits show up on reload. The container uses
`docker/config.dev.php` (setup key `dev`) and keeps the database and uploaded builds in
the `storage` Docker volume, leaving `storage/` in the repo untouched. PHP errors are
displayed. Don't upload `docker/` or `compose.yaml` to the server; `.htaccess` blocks
them anyway.

## Scripts (run from the repo root)

Copy `Scripts/web.env.example` to `Scripts/web.env` (git-ignored) and fill it in.

- `./Scripts/deploy-web.sh [--dry-run]` — publishes `Web/` over FTP/FTPS (SFTP and
  incremental mirroring with `brew install lftp`; otherwise curl uploads everything).
  Never touches `storage/` or `includes/config.local.php`, and skips `docker/`,
  `compose.yaml` and `README.md`. Set `DEPLOY_CONFIG_FILE` to upload a production config.
- `./Scripts/release.sh 1.2.0 [--notes "- …"] [--build N] [--skip-build]` — builds the
  app and DMG, uploads it in chunks (works under any PHP upload limit) with a checksum
  check, creates a **draft**, and opens its admin edit page to add notes and publish.
  Needs an API token from Admin → Account → API Tokens. Re-running replaces a draft's
  file; published versions are refused.
