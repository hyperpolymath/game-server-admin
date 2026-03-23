// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// fli-terminal.js — FLI module: ANSI escape parsing and VTE-style rendering
//
// Provides terminal-grade text rendering for panels that inherit fli-terminal.
// Used by: gsa-logs (live log streaming), gsa-actions (command output)
//
// Provisioning: loaded on-demand when a panel with fli-terminal trait is
// activated. Layers real ANSI rendering onto bare panels.
//
// API:
//   FLI.terminal.parse(text)                     — parse ANSI escapes into spans
//   FLI.terminal.render(container, text)          — render parsed text into element
//   FLI.terminal.renderLines(container, lines)    — render array of lines
//   FLI.terminal.detectURLs(html)                — linkify URLs in HTML string
//   FLI.terminal.stripAnsi(text)                  — strip all ANSI escapes

(function() {
  'use strict';

  window.FLI = window.FLI || {};
  window.FLI.terminal = {};

  // =========================================================================
  // ANSI colour maps
  // =========================================================================

  /** Standard 8 ANSI colours (foreground). */
  var ANSI_FG = {
    '30': '#484f58',  // black (dark grey)
    '31': '#f85149',  // red
    '32': '#3fb950',  // green
    '33': '#d29922',  // yellow
    '34': '#58a6ff',  // blue
    '35': '#bc8cff',  // magenta
    '36': '#39d2c0',  // cyan
    '37': '#c9d1d9',  // white (light grey)
    // Bright / bold variants
    '90': '#6e7681',
    '91': '#ff7b72',
    '92': '#56d364',
    '93': '#e3b341',
    '94': '#79c0ff',
    '95': '#d2a8ff',
    '96': '#56d4cf',
    '97': '#f0f6fc'
  };

  /** Standard 8 ANSI background colours. */
  var ANSI_BG = {
    '40': '#484f58', '41': '#f85149', '42': '#3fb950', '43': '#d29922',
    '44': '#58a6ff', '45': '#bc8cff', '46': '#39d2c0', '47': '#c9d1d9',
    '100': '#6e7681', '101': '#ff7b72', '102': '#56d364', '103': '#e3b341',
    '104': '#79c0ff', '105': '#d2a8ff', '106': '#56d4cf', '107': '#f0f6fc'
  };

  // =========================================================================
  // ANSI parser
  // =========================================================================

  /**
   * Parse a string containing ANSI escape sequences into styled HTML.
   * Handles SGR (Select Graphic Rendition) codes: colours, bold, dim,
   * italic, underline, strikethrough, inverse, and reset.
   *
   * @param {string} text - Raw text with ANSI escape sequences
   * @returns {string} HTML string with <span> elements for styling
   */
  FLI.terminal.parse = function(text) {
    if (!text) return '';

    // Match ANSI CSI sequences: ESC [ ... m
    var parts = text.split(/\x1b\[([0-9;]*)m/);
    var html = '';
    var state = { fg: null, bg: null, bold: false, dim: false, italic: false, underline: false, strike: false, inverse: false };
    var spanOpen = false;

    for (var i = 0; i < parts.length; i++) {
      if (i % 2 === 0) {
        // Text content — escape HTML and wrap in span if styled
        var escaped = escapeTermHtml(parts[i]);
        if (spanOpen) {
          html += escaped;
        } else if (hasStyle(state)) {
          html += '<span style="' + buildStyle(state) + '">' + escaped;
          spanOpen = true;
        } else {
          html += escaped;
        }
      } else {
        // ANSI code — update state
        if (spanOpen) {
          html += '</span>';
          spanOpen = false;
        }

        var codes = parts[i] ? parts[i].split(';') : ['0'];
        var j = 0;
        while (j < codes.length) {
          var code = parseInt(codes[j], 10);
          if (isNaN(code)) code = 0;

          switch (code) {
            case 0:  // Reset
              state = { fg: null, bg: null, bold: false, dim: false, italic: false, underline: false, strike: false, inverse: false };
              break;
            case 1: state.bold = true; break;
            case 2: state.dim = true; break;
            case 3: state.italic = true; break;
            case 4: state.underline = true; break;
            case 7: state.inverse = true; break;
            case 9: state.strike = true; break;
            case 22: state.bold = false; state.dim = false; break;
            case 23: state.italic = false; break;
            case 24: state.underline = false; break;
            case 27: state.inverse = false; break;
            case 29: state.strike = false; break;
            case 39: state.fg = null; break;
            case 49: state.bg = null; break;

            // 256 colour mode: ESC[38;5;Nm (fg) or ESC[48;5;Nm (bg)
            case 38:
              if (codes[j + 1] === '5' && codes[j + 2]) {
                state.fg = colour256(parseInt(codes[j + 2], 10));
                j += 2;
              }
              break;
            case 48:
              if (codes[j + 1] === '5' && codes[j + 2]) {
                state.bg = colour256(parseInt(codes[j + 2], 10));
                j += 2;
              }
              break;

            default:
              // Standard fg/bg colours
              if (ANSI_FG[String(code)]) state.fg = ANSI_FG[String(code)];
              else if (ANSI_BG[String(code)]) state.bg = ANSI_BG[String(code)];
              break;
          }
          j++;
        }
      }
    }

    if (spanOpen) html += '</span>';
    return html;
  };

  /**
   * Render parsed ANSI text into a container element.
   *
   * @param {HTMLElement|string} container - Container element or ID
   * @param {string} text - Raw text with ANSI escapes
   */
  FLI.terminal.render = function(container, text) {
    var el = typeof container === 'string' ? document.getElementById(container) : container;
    if (!el) return;
    el.innerHTML = FLI.terminal.parse(text);
  };

  /**
   * Render an array of lines into a container, each with a line number
   * and ANSI-parsed content. Supports URL detection.
   *
   * @param {HTMLElement|string} container - Container element or ID
   * @param {Array<string>} lines - Array of raw text lines
   * @param {object} options - Rendering options:
   *   lineNumbers:  {boolean} Show line numbers (default true)
   *   detectLinks:  {boolean} Make URLs clickable (default true)
   *   startLine:    {number}  First line number (default 1)
   */
  FLI.terminal.renderLines = function(container, lines, options) {
    var el = typeof container === 'string' ? document.getElementById(container) : container;
    if (!el || !lines) return;

    var opts = options || {};
    var showNums = opts.lineNumbers !== false;
    var detectLinks = opts.detectLinks !== false;
    var startLine = opts.startLine || 1;

    var html = '';
    var padWidth = String(startLine + lines.length - 1).length;

    for (var i = 0; i < lines.length; i++) {
      var parsed = FLI.terminal.parse(lines[i]);
      if (detectLinks) parsed = FLI.terminal.detectURLs(parsed);

      if (showNums) {
        var num = String(startLine + i);
        while (num.length < padWidth) num = ' ' + num;
        html += '<span style="color:#484f58;user-select:none;">' + num + '  </span>';
      }
      html += parsed + '\n';
    }

    el.innerHTML = html;
  };

  /**
   * Detect URLs in an HTML string and wrap them in clickable <a> tags.
   * Avoids double-wrapping URLs already inside tags.
   *
   * @param {string} html - HTML string (may contain <span> etc.)
   * @returns {string} HTML with URLs wrapped in <a> tags
   */
  FLI.terminal.detectURLs = function(html) {
    // Match URLs not already inside a tag attribute
    return html.replace(
      /(?<![="'])(https?:\/\/[^\s<>"']+)/g,
      '<a href="$1" style="color:#58a6ff;text-decoration:underline;" target="_blank" rel="noopener">$1</a>'
    );
  };

  /**
   * Strip all ANSI escape sequences from text, returning plain text.
   *
   * @param {string} text - Text with ANSI escapes
   * @returns {string} Plain text
   */
  FLI.terminal.stripAnsi = function(text) {
    if (!text) return '';
    return text.replace(/\x1b\[[0-9;]*m/g, '');
  };

  // =========================================================================
  // Helpers
  // =========================================================================

  /** Escape HTML entities for terminal output. */
  function escapeTermHtml(str) {
    if (!str) return '';
    return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  /** Check if the current ANSI state has any active styling. */
  function hasStyle(state) {
    return state.fg || state.bg || state.bold || state.dim || state.italic || state.underline || state.strike || state.inverse;
  }

  /** Build a CSS style string from the current ANSI state. */
  function buildStyle(state) {
    var parts = [];
    var fg = state.inverse ? state.bg : state.fg;
    var bg = state.inverse ? state.fg : state.bg;
    if (fg) parts.push('color:' + fg);
    if (bg) parts.push('background:' + bg);
    if (state.bold) parts.push('font-weight:bold');
    if (state.dim) parts.push('opacity:0.6');
    if (state.italic) parts.push('font-style:italic');
    if (state.underline) parts.push('text-decoration:underline');
    if (state.strike) parts.push('text-decoration:line-through');
    return parts.join(';');
  }

  /**
   * Convert a 256-colour index to a CSS hex colour.
   * 0-7: standard, 8-15: bright, 16-231: 6x6x6 cube, 232-255: greyscale
   */
  function colour256(n) {
    if (n < 0 || n > 255) return null;

    // Standard 16 colours
    var standard16 = [
      '#484f58', '#f85149', '#3fb950', '#d29922', '#58a6ff', '#bc8cff', '#39d2c0', '#c9d1d9',
      '#6e7681', '#ff7b72', '#56d364', '#e3b341', '#79c0ff', '#d2a8ff', '#56d4cf', '#f0f6fc'
    ];
    if (n < 16) return standard16[n];

    // 216-colour cube (6x6x6)
    if (n < 232) {
      var idx = n - 16;
      var r = Math.floor(idx / 36);
      var g = Math.floor((idx % 36) / 6);
      var b = idx % 6;
      var toHex = function(v) { var h = (v === 0 ? 0 : 55 + v * 40).toString(16); return h.length === 1 ? '0' + h : h; };
      return '#' + toHex(r) + toHex(g) + toHex(b);
    }

    // Greyscale ramp (232-255)
    var grey = 8 + (n - 232) * 10;
    var hex = grey.toString(16);
    if (hex.length === 1) hex = '0' + hex;
    return '#' + hex + hex + hex;
  }

  // Mark module as loaded
  FLI.terminal._loaded = true;
  console.log('[FLI] terminal module loaded');
})();
