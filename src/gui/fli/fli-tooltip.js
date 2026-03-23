// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// fli-tooltip.js — FLI module: rich contextual tooltips
//
// Provides rich tooltips with HTML content, auto-positioning, and delay
// for panels that inherit fli-tooltip.
// Used by: gsa-health, gsa-config, gsa-browser
//
// API:
//   FLI.tooltip.show(anchor, content, options)  — show tooltip near element
//   FLI.tooltip.hide()                          — hide active tooltip
//   FLI.tooltip.init(container)                 — auto-attach to [data-tip] elements
//   FLI.tooltip.destroy()                       — tear down all tooltips

(function() {
  'use strict';

  window.FLI = window.FLI || {};
  window.FLI.tooltip = {};

  // =========================================================================
  // State
  // =========================================================================

  var tipEl = null;        // The tooltip DOM element (singleton)
  var showTimer = null;    // Delay timer
  var hideTimer = null;    // Hide delay timer
  var currentAnchor = null;

  // =========================================================================
  // Tooltip element
  // =========================================================================

  /** Get or create the singleton tooltip element. */
  function ensureTipElement() {
    if (tipEl) return tipEl;

    tipEl = document.createElement('div');
    tipEl.id = 'fli-tooltip';
    tipEl.style.cssText =
      'position:fixed;z-index:300;max-width:320px;padding:8px 12px;'
      + 'background:#1c2128;border:1px solid #30363d;border-radius:6px;'
      + 'color:#c9d1d9;font-size:12px;line-height:1.5;font-family:system-ui,sans-serif;'
      + 'box-shadow:0 8px 24px rgba(0,0,0,0.4);pointer-events:none;'
      + 'opacity:0;transition:opacity 0.15s ease;'
      + 'word-wrap:break-word;';
    document.body.appendChild(tipEl);

    return tipEl;
  }

  // =========================================================================
  // Public API
  // =========================================================================

  /**
   * Show a tooltip near an anchor element.
   *
   * @param {HTMLElement} anchor - The element to position the tooltip near
   * @param {string} content - HTML content for the tooltip
   * @param {object} options - Configuration:
   *   position: {string} 'top' | 'bottom' | 'left' | 'right' | 'auto' (default 'auto')
   *   delay:    {number} Show delay in ms (default 300)
   *   maxWidth: {number} Max tooltip width (default 320)
   *   class:    {string} Additional CSS class
   */
  FLI.tooltip.show = function(anchor, content, options) {
    if (!anchor || !content) return;

    var opts = options || {};
    var delay = opts.delay !== undefined ? opts.delay : 300;

    clearTimeout(showTimer);
    clearTimeout(hideTimer);

    showTimer = setTimeout(function() {
      var tip = ensureTipElement();
      tip.innerHTML = content;
      if (opts.maxWidth) tip.style.maxWidth = opts.maxWidth + 'px';
      tip.style.opacity = '1';
      currentAnchor = anchor;
      positionTip(anchor, opts.position || 'auto');
    }, delay);
  };

  /**
   * Hide the active tooltip.
   *
   * @param {number} delay - Optional hide delay in ms (default 0)
   */
  FLI.tooltip.hide = function(delay) {
    clearTimeout(showTimer);
    clearTimeout(hideTimer);

    var d = delay || 0;
    hideTimer = setTimeout(function() {
      if (tipEl) {
        tipEl.style.opacity = '0';
        currentAnchor = null;
      }
    }, d);
  };

  /**
   * Initialise auto-tooltips on all [data-tip] elements within a container.
   * Supports [data-tip-pos] for positioning and [data-tip-delay] for delay.
   *
   * @param {HTMLElement|string} container - Container element or ID (default: document.body)
   */
  FLI.tooltip.init = function(container) {
    var el = typeof container === 'string' ? document.getElementById(container) : (container || document.body);

    el.addEventListener('mouseenter', function(e) {
      var target = e.target.closest('[data-tip]');
      if (target) {
        var content = target.getAttribute('data-tip');
        var pos = target.getAttribute('data-tip-pos') || 'auto';
        var delay = parseInt(target.getAttribute('data-tip-delay'), 10) || 300;
        FLI.tooltip.show(target, content, { position: pos, delay: delay });
      }
    }, true);

    el.addEventListener('mouseleave', function(e) {
      var target = e.target.closest('[data-tip]');
      if (target) {
        FLI.tooltip.hide(50);
      }
    }, true);
  };

  /**
   * Tear down the tooltip system.
   */
  FLI.tooltip.destroy = function() {
    clearTimeout(showTimer);
    clearTimeout(hideTimer);
    if (tipEl && tipEl.parentNode) {
      tipEl.parentNode.removeChild(tipEl);
    }
    tipEl = null;
    currentAnchor = null;
  };

  // =========================================================================
  // Positioning
  // =========================================================================

  /**
   * Position the tooltip relative to the anchor element.
   * In 'auto' mode, prefers top but flips to bottom if near the viewport edge.
   *
   * @param {HTMLElement} anchor - The anchor element
   * @param {string} position - Desired position ('top', 'bottom', 'left', 'right', 'auto')
   */
  function positionTip(anchor, position) {
    if (!tipEl || !anchor) return;

    var rect = anchor.getBoundingClientRect();
    var tipRect = tipEl.getBoundingClientRect();
    var gap = 8;

    var pos = position;
    if (pos === 'auto') {
      pos = rect.top > tipRect.height + gap + 20 ? 'top' : 'bottom';
    }

    var left, top;

    switch (pos) {
      case 'top':
        left = rect.left + rect.width / 2 - tipRect.width / 2;
        top = rect.top - tipRect.height - gap;
        break;
      case 'bottom':
        left = rect.left + rect.width / 2 - tipRect.width / 2;
        top = rect.bottom + gap;
        break;
      case 'left':
        left = rect.left - tipRect.width - gap;
        top = rect.top + rect.height / 2 - tipRect.height / 2;
        break;
      case 'right':
        left = rect.right + gap;
        top = rect.top + rect.height / 2 - tipRect.height / 2;
        break;
    }

    // Clamp to viewport
    left = Math.max(8, Math.min(left, window.innerWidth - tipRect.width - 8));
    top = Math.max(8, Math.min(top, window.innerHeight - tipRect.height - 8));

    tipEl.style.left = left + 'px';
    tipEl.style.top = top + 'px';
  }

  // Mark module as loaded
  FLI.tooltip._loaded = true;
  console.log('[FLI] tooltip module loaded');
})();
