document.addEventListener('DOMContentLoaded', () => {
    // 1. Mobile Navigation Hamburger & Drawer Toggle
    const mobileMenuBtn = document.getElementById('mobileMenuBtn');
    const mobileNavDrawer = document.getElementById('mobileNavDrawer');

    function closeMobileMenu() {
        if (mobileMenuBtn && mobileNavDrawer) {
            mobileMenuBtn.classList.remove('open');
            mobileNavDrawer.classList.remove('open');
        }
    }

    if (mobileMenuBtn && mobileNavDrawer) {
        mobileMenuBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            mobileMenuBtn.classList.toggle('open');
            mobileNavDrawer.classList.toggle('open');
        });

        // Close when clicking outside drawer
        document.addEventListener('click', (e) => {
            if (!mobileNavDrawer.contains(e.target) && !mobileMenuBtn.contains(e.target)) {
                closeMobileMenu();
            }
        });

        // Close on Escape key
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') closeMobileMenu();
        });
    }

    // 2. Interactive Showcase Tab Switcher
    const showcaseTabs = document.querySelectorAll('.showcase-tab');
    const showcasePanes = document.querySelectorAll('.showcase-pane');

    function activateShowcaseTab(targetTab) {
        if (!targetTab) return;
        const matchingTab = document.querySelector(`.showcase-tab[data-tab="${targetTab}"]`);
        const matchingPane = document.getElementById(`pane-${targetTab}`);

        if (matchingTab && matchingPane) {
            showcaseTabs.forEach(t => t.classList.remove('active'));
            showcasePanes.forEach(p => p.classList.remove('active'));

            matchingTab.classList.add('active');
            matchingPane.classList.add('active');
        }
    }

    showcaseTabs.forEach(tab => {
        tab.addEventListener('click', () => {
            const targetTab = tab.getAttribute('data-tab');
            activateShowcaseTab(targetTab);
        });
    });

    // 3. Smooth scrolling and smart navigation for anchor links
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function (e) {
            const targetId = this.getAttribute('href');
            if (!targetId || targetId === '#') return;

            // Close mobile menu if open
            closeMobileMenu();

            // Map nav links directly to showcase tabs when appropriate
            if (targetId === '#notebook' || targetId === '#volumes') {
                e.preventDefault();
                const tabKey = targetId.replace('#', '');
                activateShowcaseTab(tabKey);
                const showcaseSection = document.getElementById('showcase');
                if (showcaseSection) {
                    showcaseSection.scrollIntoView({ behavior: 'smooth', block: 'start' });
                }
                return;
            }

            const targetElement = document.querySelector(targetId);
            if (targetElement) {
                e.preventDefault();
                targetElement.scrollIntoView({
                    behavior: 'smooth',
                    block: 'start'
                });
            }
        });
    });

    // 4. Interactive Hero Device Mockup Controls
    const audioPlayBtn = document.getElementById('audioPlayBtn');
    const audioSpeedBtn = document.getElementById('audioSpeedBtn');
    const audioTrackSub = document.getElementById('audioTrackSub');
    const mockupIsland = document.getElementById('mockupIsland');
    const islandLabel = document.getElementById('islandLabel');
    const actionNarrationPill = document.getElementById('actionNarrationPill');
    const actionCornellPill = document.getElementById('actionCornellPill');
    const mockupTabItems = document.querySelectorAll('.mockup-tab-bar .tab-item');

    let isPlaying = true;
    const speedLevels = ['1.0x', '1.2x', '1.5x', '2.0x'];
    let currentSpeedIndex = 1; // 1.2x default
    let highlightTimer = null;

    // Simulated Live Narration Spatial Highlight Cycle
    const docParagraphs = document.querySelectorAll('.document-page .doc-paragraph');
    let currentHighlightIndex = 1; // start on the middle paragraph

    function advanceHighlight() {
        if (!isPlaying || docParagraphs.length === 0) return;

        // Clear existing highlights
        docParagraphs.forEach(p => {
            p.classList.remove('highlighted-line');
            const existingSpan = p.querySelector('.spatial-highlight');
            if (existingSpan) {
                p.innerHTML = p.innerText;
            }
        });

        // Advance to next paragraph
        currentHighlightIndex = (currentHighlightIndex + 1) % docParagraphs.length;
        const targetP = docParagraphs[currentHighlightIndex];
        if (targetP) {
            targetP.classList.add('highlighted-line');
            const rawText = targetP.innerText;
            const periodIdx = rawText.indexOf('.');
            if (periodIdx !== -1) {
                const firstPart = rawText.substring(0, periodIdx + 1);
                const restPart = rawText.substring(periodIdx + 1);
                targetP.innerHTML = `<span class="spatial-highlight">${firstPart}</span>${restPart}`;
            } else {
                targetP.innerHTML = `<span class="spatial-highlight">${rawText}</span>`;
            }
        }
    }

    function startHighlightCycle() {
        if (highlightTimer) clearInterval(highlightTimer);
        highlightTimer = setInterval(advanceHighlight, 4500);
    }

    function stopHighlightCycle() {
        if (highlightTimer) {
            clearInterval(highlightTimer);
            highlightTimer = null;
        }
    }

    startHighlightCycle();

    // Play / Pause Narration Toggle
    if (audioPlayBtn) {
        audioPlayBtn.addEventListener('click', () => {
            isPlaying = !isPlaying;
            if (isPlaying) {
                audioPlayBtn.textContent = '❚❚';
                audioPlayBtn.setAttribute('title', 'Pause Narration');
                if (audioTrackSub) audioTrackSub.textContent = 'Hands-Free Page Advancement Active';
                if (mockupIsland) mockupIsland.classList.remove('paused');
                if (islandLabel) islandLabel.textContent = `Narration Active • ${speedLevels[currentSpeedIndex]}`;
                if (actionNarrationPill) {
                    actionNarrationPill.classList.add('active-pill');
                    actionNarrationPill.textContent = '✨ Narration On';
                }
                startHighlightCycle();
            } else {
                audioPlayBtn.textContent = '▶';
                audioPlayBtn.setAttribute('title', 'Play Narration');
                if (audioTrackSub) audioTrackSub.textContent = 'Narration Paused • Tap to resume';
                if (mockupIsland) mockupIsland.classList.add('paused');
                if (islandLabel) islandLabel.textContent = `Narration Paused • ${speedLevels[currentSpeedIndex]}`;
                if (actionNarrationPill) {
                    actionNarrationPill.classList.remove('active-pill');
                    actionNarrationPill.textContent = '⏸ Narration Off';
                }
                stopHighlightCycle();
            }
        });
    }

    // Cycle Playback Speed
    if (audioSpeedBtn) {
        audioSpeedBtn.addEventListener('click', () => {
            currentSpeedIndex = (currentSpeedIndex + 1) % speedLevels.length;
            const newSpeed = speedLevels[currentSpeedIndex];
            audioSpeedBtn.textContent = newSpeed;
            if (islandLabel) {
                const statePrefix = isPlaying ? 'Narration Active' : 'Narration Paused';
                islandLabel.textContent = `${statePrefix} • ${newSpeed}`;
            }
        });
    }

    // Top HUD Action Pills
    if (actionNarrationPill && audioPlayBtn) {
        actionNarrationPill.addEventListener('click', () => {
            audioPlayBtn.click();
        });
    }

    if (actionCornellPill) {
        actionCornellPill.addEventListener('click', () => {
            activateShowcaseTab('notebook');
            const showcaseSection = document.getElementById('showcase');
            if (showcaseSection) {
                showcaseSection.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
        });
    }

    // Mockup Tab Bar click synchronization
    mockupTabItems.forEach(item => {
        item.addEventListener('click', () => {
            const tabKey = item.getAttribute('data-mockup-tab');
            mockupTabItems.forEach(t => t.classList.remove('active-tab'));
            item.classList.add('active-tab');

            if (tabKey && tabKey !== 'narration') {
                activateShowcaseTab(tabKey);
                const showcaseSection = document.getElementById('showcase');
                if (showcaseSection) {
                    showcaseSection.scrollIntoView({ behavior: 'smooth', block: 'start' });
                }
            } else if (tabKey === 'narration') {
                activateShowcaseTab('narration');
            }
        });
    });

    // 5. Subtle Card Entrance Animations via Intersection Observer
    const observerOptions = {
        root: null,
        rootMargin: '0px',
        threshold: 0.12
    };

    const revealObserver = new IntersectionObserver((entries, observer) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.style.opacity = '1';
                entry.target.style.transform = 'translateY(0)';
                observer.unobserve(entry.target);
            }
        });
    }, observerOptions);

    document.querySelectorAll('.feature-card, .comparison-container, .final-cta').forEach((el, index) => {
        el.style.opacity = '0';
        el.style.transform = 'translateY(24px)';
        el.style.transition = `opacity 0.6s cubic-bezier(0.2, 0.8, 0.2, 1), transform 0.6s cubic-bezier(0.2, 0.8, 0.2, 1) ${index * 0.05}s`;
        revealObserver.observe(el);
    });
});
