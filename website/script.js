document.addEventListener('DOMContentLoaded', () => {
    // Intersection Observer for fade-in animations
    const observerOptions = {
        threshold: 0.1,
        rootMargin: '0px 0px -50px 0px'
    };

    const observer = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.classList.add('visible');
            }
        });
    }, observerOptions);

    const fadeElements = document.querySelectorAll('.fade-in-up');
    fadeElements.forEach(el => observer.observe(el));

    // Scroll Morph Animation for Hero
    const stickyWrapper = document.querySelector('.sticky-scroll-wrapper');
    const bgImage = document.getElementById('zoom-image-bg');  // fullscreen-view-no-haven.jpeg
    const fgImage = document.getElementById('zoom-image-fg');  // dashboard.png

    if (stickyWrapper && bgImage && fgImage) {
        // Show dashboard immediately
        fgImage.classList.add('loaded');

        function animate() {
            const wrapperTop = stickyWrapper.offsetTop;
            const scrollY = window.scrollY;
            const wrapperHeight = stickyWrapper.offsetHeight;
            const windowHeight = window.innerHeight;

            const relativeScroll = scrollY - wrapperTop;

            let progress = 0;
            if (relativeScroll > -windowHeight) {
                progress = (relativeScroll + windowHeight) / (wrapperHeight + windowHeight);
            }
            progress = Math.max(0, Math.min(1, progress));

            // Use easing for smoother animation
            // Add a "HOLD" phase: keep it in start position for first 15% of scroll
            const holdThreshold = 0.15;
            let effectiveProgress = 0;

            if (progress > holdThreshold) {
                effectiveProgress = (progress - holdThreshold) / (1 - holdThreshold);
            }

            const easeOut = t => 1 - Math.pow(1 - t, 3);
            const easedProgress = easeOut(effectiveProgress);

            // ===== DASHBOARD (foreground) animation =====
            // Start large (hero) and settle to a natural desktop window size
            const fgScaleStart = 1.25; // Larger start for "sneak peak" effect
            const fgScaleEnd = 0.50;
            const fgScale = fgScaleStart - (easedProgress * (fgScaleStart - fgScaleEnd));

            const fgRotateStart = 8;
            const fgRotateEnd = 0;
            const fgRotate = fgRotateStart - (easedProgress * (fgRotateStart - fgRotateEnd));

            // Move to upper-right quadrant relative to the background image
            const bgWidth = bgImage.offsetWidth;
            const bgHeight = bgImage.offsetHeight;

            // Calculate target position in pixels relative to image center
            // X: Move right by ~26% of image width
            // Y: Move up by ~18% of image height
            const targetX = bgWidth * 0.26;
            const targetY = bgHeight * -0.18;

            const fgTranslateXStart = 0;
            const fgTranslateXEnd = targetX;
            const fgTranslateX = fgTranslateXStart + (easedProgress * (fgTranslateXEnd - fgTranslateXStart));

            // Start lower down to "sneak a preview" but closer to buttons (gap was too big)
            const fgTranslateYStart = -0.05 * bgHeight; // Slightly up from center
            const fgTranslateYEnd = targetY;
            const fgTranslateY = fgTranslateYStart + (easedProgress * (fgTranslateYEnd - fgTranslateYStart));

            // Apply transform using pixels for translation
            fgImage.style.transform = `perspective(1000px) rotateX(${fgRotate}deg) scale(${fgScale}) translate(${fgTranslateX}px, ${fgTranslateY}px)`;

            fgImage.style.opacity = 1;

            // ===== BACKGROUND (fullscreen-view) animation =====
            const bgScaleStart = 1.2;
            const bgScaleEnd = 1;
            const bgScale = bgScaleStart - (easedProgress * (bgScaleStart - bgScaleEnd));

            // Fade in the desktop wallpaper as we scroll
            let bgOpacity = 0;
            if (progress < 0.2) {
                bgOpacity = 0;
            } else if (progress < 0.6) {
                bgOpacity = (progress - 0.2) / 0.4;
            } else {
                bgOpacity = 1;
            }

            bgImage.style.transform = `scale(${bgScale})`;
            bgImage.style.opacity = bgOpacity;
        }

        window.addEventListener('scroll', animate);
        window.addEventListener('resize', animate);

        const handleLoad = () => animate();
        if (bgImage.complete) handleLoad();
        else bgImage.onload = handleLoad;

        animate();
    }

    // Smooth scrolling for anchor links
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function (e) {
            e.preventDefault();
            document.querySelector(this.getAttribute('href')).scrollIntoView({
                behavior: 'smooth'
            });
        });
    });
});
