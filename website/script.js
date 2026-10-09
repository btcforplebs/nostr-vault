document.addEventListener('DOMContentLoaded', () => {
    // Reveal-on-scroll for .fade-in-up blocks.
    const observer = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.classList.add('visible');
                observer.unobserve(entry.target);
            }
        });
    }, { threshold: 0.1, rootMargin: '0px 0px -40px 0px' });

    const revealAll = location.search.includes('reveal');
    document.querySelectorAll('.fade-in-up').forEach(el => revealAll ? el.classList.add('visible') : observer.observe(el));

    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    // Inline films start muted; a tap toggles sound and restarts from the top.
    document.querySelectorAll('video.sound-toggle').forEach(video => {
        const cap = video.parentElement.querySelector('figcaption');
        video.addEventListener('click', () => {
            video.muted = !video.muted;
            if (!video.muted) { video.currentTime = 0; video.play(); }
            if (cap) cap.textContent = `${cap.dataset.label} \u00b7 ${video.muted ? 'tap for sound' : 'tap to mute'}`;
        });
    });

    // Muted loops play only while on screen, and not at all under Reduce Motion (posters stay).
    const loops = document.querySelectorAll('.story-loop, video.sound-toggle:not([autoplay])');
    if (!reduce) {
        const player = new IntersectionObserver((entries) => {
            entries.forEach(({ target, isIntersecting }) => {
                if (isIntersecting && !document.querySelector('dialog[open]')) { target.play().catch(() => {}); }
                else if (target.muted) { target.pause(); }
            });
        }, { threshold: 0.35 });
        loops.forEach(v => player.observe(v));
    }

    // Story tiles open the full 30s cut, with sound, in a lightbox.
    const dialog = document.querySelector('.film-dialog');
    if (dialog) {
        const full = dialog.querySelector('video');
        const close = () => dialog.close();
        // Background loops hold still while a film plays, and pick up where they were after.
        let held = [];
        dialog.addEventListener('close', () => {
            full.pause(); full.removeAttribute('src'); full.load();
            held.forEach(v => v.play().catch(() => {})); held = [];
        });
        dialog.addEventListener('click', e => { if (e.target === dialog) close(); });
        dialog.querySelector('.film-close').addEventListener('click', close);
        document.querySelectorAll('.story').forEach(story => {
            story.addEventListener('click', () => {
                held = [...loops].filter(v => !v.paused);
                held.forEach(v => v.pause());
                full.src = story.dataset.film;
                full.setAttribute('aria-label', story.dataset.title);
                dialog.showModal();
                full.play().catch(() => {});
            });
        });
    }

    // Hero phones drift slightly with scroll; skipped when the user prefers reduced motion.
    const phones = document.querySelector('.hero-phones');
    if (phones && !reduce) {
        const sides = phones.querySelectorAll('.tilt-left, .tilt-right');
        let ticking = false;
        const update = () => {
            const y = Math.min(window.scrollY, 600) / 600;
            sides.forEach(el => { el.style.translate = `0 ${y * -24}px`; });
            ticking = false;
        };
        window.addEventListener('scroll', () => {
            if (!ticking) { requestAnimationFrame(update); ticking = true; }
        }, { passive: true });
    }
});
