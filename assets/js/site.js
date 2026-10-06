/* Kernel Konsulting — front end behaviour.
   Progressive enhancement only: every part of the page works without JS. */
(function () {
  'use strict';

  /* ------------------------------------------------------------- header */
  var header = document.querySelector('.site-header');
  if (header) {
    var onScroll = function () {
      header.classList.toggle('is-scrolled', window.scrollY > 8);
    };
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
  }

  /* ---------------------------------------------------------------- nav */
  var toggle = document.querySelector('.nav-toggle');
  var nav = document.getElementById('site-nav');

  if (toggle && nav) {
    var setNav = function (open) {
      toggle.setAttribute('aria-expanded', String(open));
      nav.classList.toggle('is-open', open);
      document.body.classList.toggle('nav-open', open);
    };

    toggle.addEventListener('click', function () {
      setNav(toggle.getAttribute('aria-expanded') !== 'true');
    });

    nav.addEventListener('click', function (event) {
      if (event.target.closest('a')) { setNav(false); }
    });

    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape' && nav.classList.contains('is-open')) {
        setNav(false);
        toggle.focus();
      }
    });
  }

  /* --------------------------------------------------------------- year */
  var year = document.getElementById('year');
  if (year) { year.textContent = String(new Date().getFullYear()); }

  /* --------------------------------------------------------------- form */
  var form = document.getElementById('contact-form');
  if (!form) { return; }

  var status = document.getElementById('form-status');
  var ts = form.querySelector('input[name="ts"]');
  var js = form.querySelector('input[name="js"]');
  var button = form.querySelector('button[type="submit"]');

  // Dwell-time signal: the server can reject a form posted within 2s of load.
  if (js) { js.value = '1'; }
  if (ts) { ts.value = String(Math.floor(Date.now() / 1000)); }

  function setStatus(message, state) {
    if (!status) { return; }
    status.textContent = message || '';
    if (state) { status.setAttribute('data-state', state); }
    else { status.removeAttribute('data-state'); }
  }

  function clearInvalid() {
    Array.prototype.forEach.call(form.querySelectorAll('[aria-invalid]'), function (el) {
      el.removeAttribute('aria-invalid');
    });
  }

  function resetTurnstile() {
    // Turnstile tokens are single-use, so a spent one has to be replaced
    // before the same visitor can send a second message.
    if (window.turnstile && typeof window.turnstile.reset === 'function') {
      try { window.turnstile.reset(); } catch (error) { /* widget not ready yet */ }
    }
  }

  form.addEventListener('submit', function (event) {
    if (!window.fetch || !window.FormData) { return; } // let the browser post normally

    event.preventDefault();
    clearInvalid();

    var name = form.elements.name;
    var email = form.elements.email;
    var message = form.elements.message;
    var problems = [];

    if (!name.value.trim()) { name.setAttribute('aria-invalid', 'true'); problems.push(name); }
    if (!email.value.trim() || email.value.indexOf('@') < 1) {
      email.setAttribute('aria-invalid', 'true'); problems.push(email);
    }
    if (message.value.trim().length < 10) {
      message.setAttribute('aria-invalid', 'true'); problems.push(message);
    }

    if (problems.length) {
      setStatus('Please check the highlighted fields.', 'error');
      problems[0].focus();
      return;
    }

    var original = button ? button.textContent : '';
    if (button) { button.disabled = true; button.textContent = 'Sending…'; }
    setStatus('Sending…', null);

    fetch(form.action, {
      method: 'POST',
      headers: { 'X-Requested-With': 'fetch', 'Accept': 'application/json' },
      body: new FormData(form)
    })
      .then(function (response) {
        return response.json().then(function (data) {
          return { ok: response.ok, data: data };
        });
      })
      .then(function (result) {
        if (result.ok && result.data.ok) {
          form.reset();
          if (js) { js.value = '1'; }
          if (ts) { ts.value = String(Math.floor(Date.now() / 1000)); }
          resetTurnstile();
          setStatus(result.data.message || 'Thanks — your message was sent.', 'ok');
        } else {
          resetTurnstile();
          setStatus(result.data.message || 'Sorry, something went wrong.', 'error');
        }
      })
      .catch(function () {
        resetTurnstile();
        setStatus('We could not reach the server. Please email contact@kernelkonsulting.com.', 'error');
      })
      .finally(function () {
        if (button) { button.disabled = false; button.textContent = original; }
      });
  });
})();
