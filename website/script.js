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

    // The hero film autoplays muted; a tap toggles sound and restarts it from the top.
    const film = document.querySelector('.film-main video');
    if (film) {
        film.addEventListener('click', () => {
            film.muted = !film.muted;
            if (!film.muted) { film.currentTime = 0; film.play(); }
            const cap = film.parentElement.querySelector('figcaption');
            if (cap) cap.textContent = film.muted ? 'The Door \u00b7 20 seconds \u00b7 tap for sound' : 'The Door \u00b7 20 seconds \u00b7 tap to mute';
        });
    }

    // Hero phones drift slightly with scroll; skipped when the user prefers reduced motion.
    const phones = document.querySelector('.hero-phones');
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
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
