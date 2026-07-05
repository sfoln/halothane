// Halothane landing — light progressive enhancement only.

// Sticky-nav shadow once scrolled.
const nav = document.getElementById('nav');
const onScroll = () => nav.classList.toggle('is-scrolled', window.scrollY > 8);
onScroll();
window.addEventListener('scroll', onScroll, { passive: true });

// Reveal-on-scroll for major blocks.
const targets = document.querySelectorAll(
  '.section__head, .step, .feat, .essence__card, .showcase__copy, .showcase__art, .section__narrow, .download__inner, .strip__item'
);
targets.forEach((el) => el.classList.add('reveal'));

if ('IntersectionObserver' in window) {
  const io = new IntersectionObserver((entries) => {
    entries.forEach((entry, i) => {
      if (entry.isIntersecting) {
        entry.target.style.transitionDelay = `${Math.min(i * 40, 160)}ms`;
        entry.target.classList.add('is-in');
        io.unobserve(entry.target);
      }
    });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
  targets.forEach((el) => io.observe(el));
} else {
  targets.forEach((el) => el.classList.add('is-in'));
}

// Buy flow — kicks off a Stripe Checkout Session via the store Worker.
// Set STORE_ORIGIN to the Worker's public origin (custom domain or *.workers.dev).
const STORE_ORIGIN = 'https://get.halothane.app';

document.querySelectorAll('[data-buy]').forEach((btn) => {
  btn.addEventListener('click', async (e) => {
    e.preventDefault();
    const original = btn.textContent;
    btn.setAttribute('aria-busy', 'true');
    btn.textContent = 'Redirecting to checkout…';
    try {
      const res = await fetch(`${STORE_ORIGIN}/api/checkout`, { method: 'POST' });
      const data = await res.json();
      if (data.url) { window.location.href = data.url; return; }
      throw new Error(data.error || 'Checkout unavailable');
    } catch (err) {
      btn.removeAttribute('aria-busy');
      btn.textContent = original;
      alert('Sorry — checkout is temporarily unavailable. Please try again shortly.');
    }
  });
});
