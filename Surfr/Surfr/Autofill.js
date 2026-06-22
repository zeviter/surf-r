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

  // Visibility computed across the COMPOSED tree (through shadow boundaries). A field can look visible
  // inside its own shadow root while the popup's shadow HOST (or any ancestor, inside or outside the
  // shadow tree) is display:none / visibility:hidden / opacity:0 — e.g. a login popup that's been
  // CLOSED but only hidden, not removed. Walk field → ancestors → shadow host → … → document; if any
  // is hidden, the field is not present. This is the visible-only rule the hidden-field trap relies on.
  function isVisible(el) {
    if (!el || el.type === "hidden" || el.disabled || el.readOnly) return false;
    if (!el.getClientRects().length) return false;                 // display:none anywhere / detached
    // The browser's own composed-tree visibility computation (also catches content-visibility).
    if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true, contentVisibilityAuto: true })) return false;
    let node = el;
    while (node && node.nodeType === 1) {
      const s = getComputedStyle(node);
      if (s.display === "none" || s.visibility === "hidden" || s.visibility === "collapse" || parseFloat(s.opacity || "1") === 0) return false;
      // An ancestor collapsed to zero in a clipped axis (e.g. height:0;overflow:hidden — a common
      // close/animation pattern) hides its subtree even though the field's own box is non-zero.
      // `display:contents` boxes have no geometry but DO render children — never exclude on those.
      if (node !== el && s.display !== "contents") {
        if ((node.offsetHeight === 0 && s.overflowY !== "visible") || (node.offsetWidth === 0 && s.overflowX !== "visible")) return false;
      }
      const parent = node.parentNode;
      node = (parent instanceof ShadowRoot) ? parent.host : parent;   // cross the shadow boundary
    }
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;                 // zero-size
    if (r.right <= 0 || r.bottom <= 0) return false;               // off-screen above/left (e.g. -9999px)
    return true;
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
  // username when there's corroborating sign-in context — so newsletter/contact/home pages don't
  // trigger. autocomplete=username/email (the STRONG path) bypasses this entirely.
  //
  // IMPORTANT: a login PAGE signal (URL/title is a sign-in page, or the field's own form posts to a
  // login endpoint, or a sign-in HEADING) — NOT a page-level "Log in" button/link (every home page has
  // one). Using button text corroborated a home page's search box as a username field — a real
  // security regression. Headings only (h1/h2/legend), never buttons/links.
  function loginContext(field) {
    const hay = (location.href + " " + document.title).toLowerCase();
    if (/sign[\s-]?in|log[\s-]?in|signin|login|\/auth|\/account|sso/.test(hay)) return true;
    const action = ((field && field.form && field.form.getAttribute("action")) || "").toLowerCase();
    if (/sign[\s-]?in|log[\s-]?in|signin|login|auth|sso/.test(action)) return true;
    const headings = document.querySelectorAll("h1,h2,h3,legend,[role=heading]");
    return Array.prototype.some.call(headings, (e) => /sign\s?in|log\s?in/.test((e.textContent || "").toLowerCase()));
  }

  // Exclude search/query boxes — they must never be treated as login fields or receive a fill, even on
  // a login page or a page with a sign-in heading.
  function looksLikeSearch(el) {
    if ((el.type || "").toLowerCase() === "search") return true;
    const meta = ((el.name || "") + " " + (el.id || "") + " " + (el.getAttribute("aria-label") || "") + " " + (el.placeholder || "")).toLowerCase();
    if (/search|\bquery\b|\bq\b/.test(meta)) return true;
    const formAction = ((el.form && el.form.getAttribute("action")) || "").toLowerCase();
    if (/search/.test(formAction)) return true;
    const role = ((el.getAttribute("role") || "") + " " + ((el.form && el.form.getAttribute("role")) || "")).toLowerCase();
    return role.includes("search");
  }

  // A username field on a username-FIRST (two-step) page: only when there's NO visible password field.
  function usernameCandidate() {
    if (passwordFields().length) return null;
    const inputs = deepQueryAll("input").filter(isVisible).filter((el) => !looksLikeSearch(el));
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
    const fields = deepQueryAll(sel).filter(isVisible).filter((el) => !looksLikeSearch(el));
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

  // ── Save capture (Slice 8b) ───────────────────────────────────────────────────────────────────
  // The ONLY place this script reads field VALUES — and only on an explicit submit GESTURE of a
  // detected single-password login form. No keystroke logging, no beforeunload heuristic (which would
  // misfire on abandoned half-filled forms): we capture on real submit / Enter-in-password /
  // submit-ish button click. Tight trigger: exactly one VISIBLE password (excludes change/signup
  // forms with current+new+confirm) with a non-empty value, reusing isVisible (hidden-field-trap safe).
  let lastKey = "", lastAt = 0;

  function usernameInScope(root, pw) {
    const sel = 'input[autocomplete="username"], input[type="text"], input[type="email"], input[type="tel"], input:not([type])';
    const q = root === document ? deepQueryAll(sel) : Array.prototype.slice.call(root.querySelectorAll(sel));
    const fields = q.filter((el) => isVisible(el) && !looksLikeSearch(el));
    const explicit = fields.find((el) => (el.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/).includes("username"));
    if (explicit) return explicit;
    let best = null;
    for (const el of fields) { try { if (pw.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_PRECEDING) best = el; } catch (e) { /* cross-root */ } }
    return best || fields[0] || null;
  }

  function maybeCapture(scope) {
    const root = scope && scope.querySelectorAll ? scope : document;
    const pws = (root === document ? passwordFields()
                 : Array.prototype.filter.call(root.querySelectorAll('input[type="password"]'), isVisible));
    if (pws.length !== 1) return;            // exactly one visible password — not change/signup
    const pw = pws[0];
    if (!pw.value) return;                   // non-empty
    const u = usernameInScope(root, pw);
    const username = u ? u.value : "";
    if (!username) return;   // require a non-empty adjacent username — password-only pages (two-step
                             // page 2) can't be deduped, so capturing would spuriously re-offer the
                             // just-filled credential. Two-step page-1→2 capture deferred to v1.5.
    const key = username + " " + pw.value;
    const now = (window.performance && performance.now) ? performance.now() : 0;
    if (key === lastKey && now - lastAt < 1500) return;   // dedup rapid duplicate gestures
    lastKey = key; lastAt = now;
    HANDLER.postMessage({ type: "submitted", username: username, password: pw.value });
  }

  function isSubmitish(el) {
    if (!el || !el.tagName) return false;
    if (el.tagName === "INPUT") return /submit/i.test(el.type || "");
    if (el.tagName === "BUTTON") {
      const t = (el.type || "submit").toLowerCase();   // a <button> defaults to type=submit
      return t === "submit" || /sign\s?in|log\s?in|sign\s?on|continue|next/i.test(el.textContent || "");
    }
    return false;
  }

  document.addEventListener("submit", (e) => {
    maybeCapture((e.composedPath && e.composedPath()[0]) || e.target);
  }, true);

  document.addEventListener("keydown", (e) => {
    if (e.key !== "Enter") return;
    const t = (e.composedPath && e.composedPath()[0]) || e.target;
    if (t && t.tagName === "INPUT" && (t.type || "").toLowerCase() === "password") maybeCapture(t.form || null);
  }, true);

  document.addEventListener("click", (e) => {
    const path = (e.composedPath && e.composedPath()) || [e.target];
    if (!path.some(isSubmitish)) return;     // only submit-ish buttons (not a show-password toggle)
    const btn = path.find(isSubmitish);
    maybeCapture(btn.form || (btn.closest && btn.closest("form")) || null);
  }, true);

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
