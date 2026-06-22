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

  function passwordFields() {
    return Array.prototype.filter.call(document.querySelectorAll('input[type="password"]'), isVisible);
  }

  // STRUCTURE ONLY — no values.
  function detect() {
    HANDLER.postMessage({ type: "detected", origin: location.origin, hasPassword: passwordFields().length > 0 });
  }

  // Username field for a password field: explicit autocomplete=username, else the nearest visible
  // text-ish input preceding it in DOM order (same form if any).
  function usernameFor(pw) {
    const scope = pw.form || document;
    const sel = 'input[autocomplete="username"], input[type="text"], input[type="email"], input[type="tel"], input:not([type])';
    const fields = Array.prototype.filter.call(scope.querySelectorAll(sel), isVisible);
    const explicit = fields.find((el) => el.autocomplete === "username");
    if (explicit) return explicit;
    let best = null;
    for (const el of fields) {
      if (pw.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_PRECEDING) best = el;
    }
    return best || fields[0] || null;
  }

  function setValue(el, value) {
    el.focus();
    el.value = value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

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
