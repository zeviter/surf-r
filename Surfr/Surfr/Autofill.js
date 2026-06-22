// surf-r in-browser autofill — injected at document-start into EVERY frame, in an ISOLATED
// WKContentWorld (the page cannot read, override, or call this script or its message handler).
//
// PRIVACY CONTRACT (audited):
//   • Egresses NOTHING. The only sink is webkit.messageHandlers.surfrAutofill.postMessage to native.
//   • Detection reports STRUCTURE ONLY — { hasPassword } + the frame's own origin. Never field
//     values, never page content, never keystrokes. (Reading values is the Slice-8b save path, not
//     here.)
//   • __surfrFill (invoked by native via callAsyncJavaScript in THIS world) writes values into
//     VISIBLE fields only and returns booleans only — never values.
(function () {
  "use strict";
  const HANDLER =
    (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.surfrAutofill) || null;
  if (!HANDLER) return;

  function isVisible(el) {
    if (!el || el.type === "hidden" || el.disabled || el.readOnly) return false;
    if (!el.getClientRects().length || el.offsetParent === null) return false;
    const s = getComputedStyle(el);
    return s.visibility !== "hidden" && s.display !== "none";
  }

  // Query that pierces OPEN shadow roots (login popups/modals are often web components). Closed roots
  // remain inaccessible by design — documented limit. Cost is bounded by the detection debounce.
  function deepQueryAll(selector) {
    const out = [];
    function walk(root) {
      let matches; try { matches = root.querySelectorAll(selector); } catch (e) { matches = []; }
      for (const m of matches) out.push(m);
      let all; try { all = root.querySelectorAll("*"); } catch (e) { all = []; }
      for (const el of all) { if (el.shadowRoot) walk(el.shadowRoot); }
    }
    walk(document);
    return out;
  }

  function passwordFields() {
    return deepQueryAll('input[type="password"]').filter(isVisible);
  }

  // Login context for the WEAK (bare type=email/text) path: only treat such a field as a login
  // username when there's corroborating sign-in context — so newsletter/contact/quote forms don't
  // trigger. autocomplete=username/email (the STRONG path) bypasses this entirely.
  function loginContext(field) {
    const hay = (location.href + " " + document.title).toLowerCase();
    if (/sign[\s-]?in|log[\s-]?in|signin|login|\/auth|\/account|sso/.test(hay)) return true;
    const action = ((field && field.form && field.form.getAttribute("action")) || "").toLowerCase();
    if (/sign[\s-]?in|log[\s-]?in|signin|login|auth|sso/.test(action)) return true;
    const headings = document.querySelectorAll("h1,h2,h3,legend,button,[type=submit],[role=heading]");
    return Array.prototype.some.call(headings, (e) => /sign\s?in|log\s?in/.test((e.textContent || "").toLowerCase()));
  }

  // A username field on a username-FIRST (two-step) page: only when there's NO visible password field.
  function usernameCandidate() {
    if (passwordFields().length) return null;
    const inputs = deepQueryAll("input").filter(isVisible);
    // STRONG, trusted: autocomplete=username / email.
    const strong = inputs.find((el) => {
      const ac = (el.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/);
      return ac.includes("username") || ac.includes("email");
    });
    if (strong) return strong;
    // WEAK: bare email/text — require login-context corroboration.
    const weak = inputs.filter((el) => { const t = (el.type || "text").toLowerCase(); return t === "email" || t === "text"; });
    return weak.find((el) => loginContext(el)) || null;
  }

  // Compute current detection (structure only) — shared by the pushed observer message and the
  // on-demand request native makes at ⌘\ press time (so a press never relies on a stale 800ms scan).
  function snapshot() {
    const hasPassword = passwordFields().length > 0;
    return { hasPassword: hasPassword, hasUsername: !hasPassword && usernameCandidate() !== null };
  }

  // Invoked by native at ⌘\ press (callAsyncJavaScript) for a FRESH read of this frame, right now.
  globalThis.__surfrDetect = function () { return snapshot(); };

  // STRUCTURE ONLY — no values.
  function detect() {
    const s = snapshot();
    HANDLER.postMessage({ type: "detected", origin: location.origin, hasPassword: s.hasPassword, hasUsername: s.hasUsername });
  }

  // Username field for a password field: explicit autocomplete=username, else the nearest visible
  // text-ish input preceding it in DOM order (same form if any).
  function usernameFor(pw) {
    const sel = 'input[autocomplete="username"], input[type="text"], input[type="email"], input[type="tel"], input:not([type])';
    const fields = deepQueryAll(sel).filter(isVisible);
    const explicit = fields.find((el) => (el.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/).includes("username"));
    if (explicit) return explicit;
    let best = null;
    for (const el of fields) {
      try { if (pw.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_PRECEDING) best = el; } catch (e) { /* cross-root */ }
    }
    return best || fields[0] || null;
  }

  function setValue(el, value) {
    el.focus();
    el.value = value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  // Fill ONLY the username on a username-first page (no password is sent to the page on step 1).
  globalThis.__surfrFillUsername = function (username) {
    const u = usernameCandidate();
    if (!u) return { filledUsername: false };
    setValue(u, username);
    return { filledUsername: true };
  };

  // Invoked by native (this content world). Fills VISIBLE fields only; returns booleans only.
  globalThis.__surfrFill = function (username, password) {
    const pws = passwordFields();
    if (!pws.length) return { filledPassword: false, filledUsername: false };
    const pw = pws[0];
    let filledUsername = false;
    if (username) {
      const u = usernameFor(pw);
      if (u) { setValue(u, username); filledUsername = true; }
    }
    setValue(pw, password);
    return { filledPassword: true, filledUsername: filledUsername };
  };

  // Initial detection + AGGRESSIVELY debounced re-scan for SPA/dynamic forms. The observer callback
  // only re-runs structure-only detect(); it never reads content. At most one detect per window.
  let timer = null;
  function schedule() {
    if (timer) return;                                  // coalesce mutation bursts
    timer = setTimeout(function () { timer = null; detect(); }, 800);
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", detect, { once: true });
  } else {
    detect();
  }
  new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
})();
