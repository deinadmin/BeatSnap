(() => {
    const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    // Nav hairline once the page scrolls.
    const nav = document.querySelector('.nav');
    const onScroll = () => nav?.classList.toggle('is-scrolled', window.scrollY > 8);
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });

    // Scroll reveal. Elements also start their CSS animations once visible.
    const revealer = new IntersectionObserver((entries) => {
        for (const entry of entries) {
            if (entry.isIntersecting) {
                entry.target.classList.add('is-visible');
                revealer.unobserve(entry.target);
            }
        }
    }, { rootMargin: '0px 0px -12% 0px', threshold: 0.15 });
    document.querySelectorAll('[data-reveal]').forEach((el) => revealer.observe(el));

    // Waveforms for the DAW clips: deterministic so they look the same on every visit.
    document.querySelectorAll('.wave').forEach((wave, w) => {
        const bars = Math.round(wave.parentElement.offsetWidth / 5) || 48;
        const fragment = document.createDocumentFragment();
        for (let i = 0; i < bars; i++) {
            const beat = i % 8 === 0 ? 1 : i % 4 === 0 ? 0.75 : 0.45;
            const noise = Math.abs(Math.sin((i + 1) * (w + 1.7) * 12.9898) * 43758.5453) % 1;
            const bar = document.createElement('i');
            bar.style.setProperty('--h', `${Math.round(18 + 78 * beat * (0.55 + noise * 0.45))}%`);
            fragment.append(bar);
        }
        wave.append(fragment);
    });

    // Paste demo: type a link, press Download, watch it arrive with BPM and key.
    const demo = document.querySelector('[data-paste-demo]');
    if (!demo || reduceMotion) {
        document.querySelector('[data-source="youtube"]')?.classList.add('is-active');
        return;
    }

    const items = [
        { source: 'youtube', url: 'youtube.com/watch?v=Jx8f2kQ', title: 'midnight drive (prod. nova)', bpm: '140 BPM', key: 'F# minor', time: '2:48' },
        { source: 'drive', url: 'drive.google.com/file/d/1aB7xQ/view', title: 'club & 2000s.wav', bpm: '110 BPM', key: 'A minor', time: '2:55' },
        { source: 'dropbox', url: 'dropbox.com/scl/fi/k2p/vento.mp3', title: 'vento.mp3', bpm: '133 BPM', key: 'A minor', time: '3:40' },
        { source: 'direct', url: 'beats.example.com/slay.wav', title: 'slay.wav', bpm: '164 BPM', key: 'E major', time: '2:35' },
    ];
    const field = demo.querySelector('[data-url]');
    const button = demo.querySelector('[data-go]');
    const rows = demo.querySelector('[data-rows]');
    const template = demo.querySelector('[data-result]');
    const sources = document.querySelectorAll('[data-source]');

    let running = false;
    let index = 0;
    let generation = 0;
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    const makeRow = (item) => {
        const row = template.cloneNode(true);
        row.removeAttribute('data-result');
        row.classList.remove('beat-row--dim');
        row.classList.add('is-new', 'is-analysing');
        row.querySelector('[data-title]').textContent = item.title;
        row.querySelector('[data-bpm]').textContent = item.bpm;
        row.querySelector('[data-key]').textContent = item.key;
        row.querySelector('[data-time]').textContent = item.time;
        return row;
    };

    const cycle = async (run) => {
        while (running && run === generation) {
            const item = items[index % items.length];
            sources.forEach((s) => s.classList.toggle('is-active', s.dataset.source === item.source));

            field.textContent = '';
            await sleep(500);
            for (const char of item.url) {
                if (run !== generation) return;
                field.textContent += char;
                await sleep(28 + Math.random() * 30);
            }
            button.classList.add('is-ready');
            await sleep(450);
            button.classList.add('is-pressed');
            await sleep(160);
            button.classList.remove('is-pressed', 'is-ready');
            field.textContent = '';

            const row = makeRow(item);
            rows.querySelectorAll('.beat-row').forEach((r) => r.classList.add('beat-row--dim'));
            rows.prepend(row);
            while (rows.children.length > 3) rows.lastElementChild.remove();
            await sleep(1100);
            row.classList.remove('is-analysing');
            await sleep(2200);
            index++;
        }
    };

    new IntersectionObserver(([entry]) => {
        running = entry.isIntersecting;
        if (running) {
            generation++;
            cycle(generation);
        }
    }, { threshold: 0.3 }).observe(demo);
})();
