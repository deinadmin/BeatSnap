(() => {
    // Copy-to-clipboard buttons: <button data-copy="#selector">
    document.querySelectorAll('[data-copy]').forEach((button) => {
        button.addEventListener('click', async () => {
            const text = document.querySelector(button.dataset.copy)?.textContent.trim() ?? '';
            try {
                await navigator.clipboard.writeText(text);
                const label = button.textContent;
                button.textContent = 'Copied';
                setTimeout(() => { button.textContent = label; }, 1400);
            } catch {
                window.prompt('Copy this link:', text);
            }
        });
    });

    // Confirmation for destructive forms: <form data-confirm="…">
    document.querySelectorAll('form[data-confirm]').forEach((form) => {
        form.addEventListener('submit', (event) => {
            if (!window.confirm(form.dataset.confirm)) event.preventDefault();
        });
    });

    const form = document.querySelector('form[data-upload]');
    if (!form) return;

    // File picker / drop zone label.
    const input = form.querySelector('input[type="file"]');
    const zone = form.querySelector('.dropzone');
    const label = form.querySelector('[data-file-label]');
    const formatSize = (bytes) => bytes > 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : `${Math.round(bytes / 1e6)} MB`;
    const showFile = () => {
        const file = input.files[0];
        label.textContent = file ? `${file.name} — ${formatSize(file.size)}` : 'Choose a .dmg, .zip or .pkg';
        zone.classList.toggle('has-file', !!file);
        if (file) {
            const radio = form.querySelector('input[name="source"][value="upload"]');
            if (radio) radio.checked = true;
            const version = form.querySelector('input[name="version"]');
            const match = file.name.match(/(\d+(?:\.\d+){1,3})/);
            if (version && !version.value && match) version.value = match[1];
        }
    };
    input?.addEventListener('change', showFile);
    ['dragenter', 'dragover'].forEach((type) => zone?.addEventListener(type, () => zone.classList.add('is-over')));
    ['dragleave', 'drop'].forEach((type) => zone?.addEventListener(type, () => zone.classList.remove('is-over')));

    // Upload with progress. Falls back to a normal form post without JavaScript.
    const progress = form.querySelector('.progress');
    const bar = form.querySelector('.progress__bar');
    const progressLabel = form.querySelector('.progress__label');
    const errorSlot = document.getElementById('form-error');
    const submit = form.querySelector('button[type="submit"]');

    form.addEventListener('submit', (event) => {
        event.preventDefault();
        const uploading = form.querySelector('input[name="source"]:checked')?.value === 'upload' && input.files.length > 0;
        const request = new XMLHttpRequest();
        request.open('POST', form.action || window.location.href);
        request.setRequestHeader('X-Requested-With', 'fetch');
        request.responseType = 'json';

        submit.disabled = true;
        errorSlot.innerHTML = '';
        if (uploading) {
            progress.hidden = false;
            request.upload.addEventListener('progress', (e) => {
                if (!e.lengthComputable) return;
                const fraction = e.loaded / e.total;
                bar.style.width = `${(fraction * 100).toFixed(1)}%`;
                progressLabel.textContent = fraction < 1
                    ? `Uploading… ${Math.round(fraction * 100)}%`
                    : 'Verifying…';
            });
        }

        const fail = (message) => {
            submit.disabled = false;
            progress.hidden = true;
            const banner = document.createElement('div');
            banner.className = 'banner banner--error';
            banner.setAttribute('role', 'alert');
            banner.textContent = message;
            errorSlot.replaceChildren(banner);
            window.scrollTo({ top: 0, behavior: 'smooth' });
        };

        request.addEventListener('load', () => {
            const body = request.response;
            if (body?.redirect) {
                window.location.href = body.redirect;
            } else {
                fail(body?.error ?? `The server responded with an error (${request.status}).`);
            }
        });
        request.addEventListener('error', () => fail('The connection was interrupted. Please try again.'));
        request.send(new FormData(form));
    });
})();
