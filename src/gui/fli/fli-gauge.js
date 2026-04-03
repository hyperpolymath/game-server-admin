// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// fli-gauge.js — FLI module: SVG arc gauges, ring meters, and sparkline charts
//
// Provides visual data representations for panels that inherit fli-gauge.
// Used by: gsa-health (drift gauges, modality rings), gsa-browser (mini sparklines)
//
// API:
//   FLI.gauge.arc(container, value, max, options)   — render an SVG arc gauge
//   FLI.gauge.ring(container, value, max, options)   — render a full ring meter
//   FLI.gauge.sparkline(container, data, options)   — render a mini sparkline
//   FLI.gauge.multiArc(container, values, options)  — render overlapping arcs

(function() {
  'use strict';

  // Ensure FLI namespace exists
  window.FLI = window.FLI || {};
  window.FLI.gauge = {};

  // =========================================================================
  // Colour utilities
  // =========================================================================

  /**
   * Get a colour for a normalised value (0.0 = good/green, 1.0 = bad/red).
   * Returns a CSS colour string interpolated through green → yellow → red.
   *
   * @param {number} value - Normalised value (0.0 to 1.0)
   * @returns {string} CSS colour string
   */
  /**
   * Escape special XML/SVG characters in a string to prevent injection.
   * Must be applied to any user-supplied text before embedding in SVG.
   *
   * @param {string} str - Raw string
   * @returns {string} XML-escaped string safe for SVG text content
   */
  function escapeXml(str) {
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function valueColour(value) {
    if (value < 0.2) return '#3fb950';
    if (value < 0.4) return '#7ec84a';
    if (value < 0.6) return '#d29922';
    if (value < 0.8) return '#e5783e';
    return '#f85149';
  }

  /**
   * Get a colour for a positive metric (higher = better).
   *
   * @param {number} value - Normalised value (0.0 to 1.0)
   * @returns {string} CSS colour string
   */
  function positiveColour(value) {
    return valueColour(1.0 - value);
  }

  // =========================================================================
  // SVG Arc Gauge
  // =========================================================================

  /**
   * Render an SVG arc gauge into a container element.
   * The arc sweeps from the bottom-left to the bottom-right (a 240-degree arc)
   * with the value portion filled and the remainder as a track.
   *
   * @param {HTMLElement|string} container - Container element or ID
   * @param {number} value - Current value
   * @param {number} max - Maximum value (arc represents 0 to max)
   * @param {object} options - Rendering options:
   *   size:        {number}  Diameter in px (default 120)
   *   strokeWidth: {number}  Arc stroke width (default 10)
   *   label:       {string}  Text label below the value (optional)
   *   unit:        {string}  Unit suffix (e.g. '%', 'ms') (optional)
   *   precision:   {number}  Decimal places for value display (default 1)
   *   invert:      {boolean} If true, higher values are better (default false)
   *   animate:     {boolean} Animate on first render (default true)
   *   trackColour: {string}  Track colour (default 'rgba(48,54,61,0.6)')
   */
  FLI.gauge.arc = function(container, value, max, options) {
    var el = typeof container === 'string' ? document.getElementById(container) : container;
    if (!el) return;

    var opts = options || {};
    var size       = opts.size || 120;
    var stroke     = opts.strokeWidth || 10;
    var label      = opts.label || '';
    var unit       = opts.unit || '';
    var precision  = opts.precision !== undefined ? opts.precision : 1;
    var invert     = opts.invert || false;
    var animate    = opts.animate !== false;
    var trackCol   = opts.trackColour || 'rgba(48,54,61,0.6)';

    var radius     = (size - stroke) / 2;
    var cx         = size / 2;
    var cy         = size / 2;
    var normalised = max > 0 ? Math.min(value / max, 1.0) : 0;
    var colour     = invert ? positiveColour(normalised) : valueColour(normalised);

    // Arc geometry: 240-degree arc, starting at 150 degrees (bottom-left)
    var startAngle = 150;
    var totalSweep = 240;
    var valueSweep = totalSweep * normalised;

    function polarToCartesian(angle) {
      var rad = (angle - 90) * Math.PI / 180;
      return {
        x: cx + radius * Math.cos(rad),
        y: cy + radius * Math.sin(rad)
      };
    }

    function arcPath(startDeg, sweepDeg) {
      if (sweepDeg <= 0) return '';
      var start = polarToCartesian(startDeg);
      var end   = polarToCartesian(startDeg + sweepDeg);
      var large = sweepDeg > 180 ? 1 : 0;
      return 'M ' + start.x + ' ' + start.y
        + ' A ' + radius + ' ' + radius + ' 0 ' + large + ' 1 '
        + end.x + ' ' + end.y;
    }

    var trackPath = arcPath(startAngle, totalSweep);
    var valuePath = arcPath(startAngle, valueSweep);

    var displayValue = value.toFixed(precision);
    var animId = 'fli-arc-' + Math.random().toString(36).substr(2, 6);

    var svg = '<svg width="' + size + '" height="' + size + '" viewBox="0 0 ' + size + ' ' + size + '">'
      // Track
      + '<path d="' + trackPath + '" fill="none" stroke="' + trackCol + '" stroke-width="' + stroke + '" stroke-linecap="round" />'
      // Value arc
      + '<path id="' + animId + '" d="' + valuePath + '" fill="none" stroke="' + colour + '" stroke-width="' + stroke + '" stroke-linecap="round"'
      + (animate ? ' style="filter:drop-shadow(0 0 4px ' + colour + ');"' : '')
      + ' />'
      // Centre value text
      + '<text x="' + cx + '" y="' + (cy - 2) + '" text-anchor="middle" dominant-baseline="central"'
      + ' fill="' + colour + '" font-size="' + Math.round(size / 4.5) + '" font-weight="700" font-family="system-ui, sans-serif">'
      + displayValue + unit
      + '</text>';

    if (label) {
      svg += '<text x="' + cx + '" y="' + (cy + Math.round(size / 5)) + '" text-anchor="middle"'
        + ' fill="#8b949e" font-size="' + Math.round(size / 11) + '" font-family="system-ui, sans-serif">'
        + escapeXml(label) + '</text>';
    }

    svg += '</svg>';
    el.innerHTML = svg;
  };

  // =========================================================================
  // Ring Meter (full 360-degree)
  // =========================================================================

  /**
   * Render a full 360-degree ring meter.
   *
   * @param {HTMLElement|string} container - Container element or ID
   * @param {number} value - Current value (0.0 to 1.0 normalised)
   * @param {object} options - Same as arc() plus:
   *   innerLabel: {string} Text inside the ring (default: percentage)
   */
  FLI.gauge.ring = function(container, value, options) {
    var el = typeof container === 'string' ? document.getElementById(container) : container;
    if (!el) return;

    var opts = options || {};
    var size       = opts.size || 80;
    var stroke     = opts.strokeWidth || 6;
    var label      = opts.label || '';
    var invert     = opts.invert || false;
    var trackCol   = opts.trackColour || 'rgba(48,54,61,0.6)';

    var radius     = (size - stroke) / 2;
    var cx         = size / 2;
    var cy         = size / 2;
    var circumference = 2 * Math.PI * radius;
    var normalised = Math.max(0, Math.min(value, 1.0));
    var colour     = invert ? positiveColour(normalised) : valueColour(normalised);
    var dashOffset = circumference * (1 - normalised);

    var pct = (normalised * 100).toFixed(0);
    var innerLabel = opts.innerLabel !== undefined ? opts.innerLabel : pct + '%';

    var svg = '<svg width="' + size + '" height="' + size + '" viewBox="0 0 ' + size + ' ' + size + '">'
      // Track circle
      + '<circle cx="' + cx + '" cy="' + cy + '" r="' + radius + '" fill="none" stroke="' + trackCol + '" stroke-width="' + stroke + '" />'
      // Value circle (rotated -90 to start from top)
      + '<circle cx="' + cx + '" cy="' + cy + '" r="' + radius + '" fill="none" stroke="' + colour + '" stroke-width="' + stroke + '"'
      + ' stroke-dasharray="' + circumference + '" stroke-dashoffset="' + dashOffset + '"'
      + ' stroke-linecap="round" transform="rotate(-90 ' + cx + ' ' + cy + ')"'
      + ' style="transition:stroke-dashoffset 0.6s ease;filter:drop-shadow(0 0 3px ' + colour + ');" />'
      // Centre text
      + '<text x="' + cx + '" y="' + (cy - (label ? 4 : 0)) + '" text-anchor="middle" dominant-baseline="central"'
      + ' fill="' + colour + '" font-size="' + Math.round(size / 5) + '" font-weight="700" font-family="system-ui, sans-serif">'
      + innerLabel + '</text>';

    if (label) {
      svg += '<text x="' + cx + '" y="' + (cy + Math.round(size / 5.5)) + '" text-anchor="middle"'
        + ' fill="#8b949e" font-size="' + Math.round(size / 9) + '" font-family="system-ui, sans-serif">'
        + escapeXml(label) + '</text>';
    }

    svg += '</svg>';
    el.innerHTML = svg;
  };

  // =========================================================================
  // Sparkline
  // =========================================================================

  /**
   * Render a mini sparkline chart from an array of data points.
   * The sparkline is a simple polyline SVG with optional area fill.
   *
   * @param {HTMLElement|string} container - Container element or ID
   * @param {Array<number>} data - Array of numeric data points
   * @param {object} options - Rendering options:
   *   width:      {number}  Chart width (default 120)
   *   height:     {number}  Chart height (default 32)
   *   colour:     {string}  Line colour (default '#58a6ff')
   *   fill:       {boolean} Fill area under line (default true)
   *   strokeWidth:{number}  Line width (default 1.5)
   *   showDot:    {boolean} Show dot at latest value (default true)
   */
  FLI.gauge.sparkline = function(container, data, options) {
    var el = typeof container === 'string' ? document.getElementById(container) : container;
    if (!el || !data || data.length === 0) return;

    var opts = options || {};
    var w      = opts.width || 120;
    var h      = opts.height || 32;
    var colour = opts.colour || '#58a6ff';
    var fill   = opts.fill !== false;
    var sw     = opts.strokeWidth || 1.5;
    var showDot = opts.showDot !== false;

    var min = Math.min.apply(null, data);
    var max = Math.max.apply(null, data);
    var range = max - min || 1;
    var padding = 2;

    // Build polyline points
    var points = [];
    for (var i = 0; i < data.length; i++) {
      var x = padding + (i / (data.length - 1)) * (w - padding * 2);
      var y = h - padding - ((data[i] - min) / range) * (h - padding * 2);
      points.push(x.toFixed(1) + ',' + y.toFixed(1));
    }

    var polyline = points.join(' ');

    // Area fill path (close at the bottom)
    var areaPath = '';
    if (fill) {
      areaPath = '<polygon points="' + padding + ',' + (h - padding) + ' '
        + polyline + ' '
        + (w - padding) + ',' + (h - padding) + '"'
        + ' fill="' + colour + '" fill-opacity="0.1" />';
    }

    // Latest dot
    var dot = '';
    if (showDot && points.length > 0) {
      var lastParts = points[points.length - 1].split(',');
      dot = '<circle cx="' + lastParts[0] + '" cy="' + lastParts[1] + '" r="2.5"'
        + ' fill="' + colour + '" stroke="#0d1117" stroke-width="1" />';
    }

    var svg = '<svg width="' + w + '" height="' + h + '" viewBox="0 0 ' + w + ' ' + h + '">'
      + areaPath
      + '<polyline points="' + polyline + '" fill="none" stroke="' + colour + '" stroke-width="' + sw + '" stroke-linejoin="round" stroke-linecap="round" />'
      + dot
      + '</svg>';

    el.innerHTML = svg;
  };

  // =========================================================================
  // Multi-Arc (overlapping arcs on one gauge)
  // =========================================================================

  /**
   * Render multiple overlapping arc gauges in a single SVG.
   * Each arc is a different colour and value, sharing the same centre.
   *
   * @param {HTMLElement|string} container - Container element or ID
   * @param {Array<object>} values - Array of {value, max, label, colour} objects
   * @param {object} options - Rendering options (size, strokeWidth, gap)
   */
  FLI.gauge.multiArc = function(container, values, options) {
    var el = typeof container === 'string' ? document.getElementById(container) : container;
    if (!el || !values || values.length === 0) return;

    var opts = options || {};
    var size   = opts.size || 160;
    var stroke = opts.strokeWidth || 8;
    var gap    = opts.gap || 4;
    var cx     = size / 2;
    var cy     = size / 2;

    var startAngle = 150;
    var totalSweep = 240;

    function polarToCartesian(radius, angle) {
      var rad = (angle - 90) * Math.PI / 180;
      return { x: cx + radius * Math.cos(rad), y: cy + radius * Math.sin(rad) };
    }

    function arcPath(radius, startDeg, sweepDeg) {
      if (sweepDeg <= 0) return '';
      var start = polarToCartesian(radius, startDeg);
      var end   = polarToCartesian(radius, startDeg + sweepDeg);
      var large = sweepDeg > 180 ? 1 : 0;
      return 'M ' + start.x + ' ' + start.y + ' A ' + radius + ' ' + radius + ' 0 ' + large + ' 1 ' + end.x + ' ' + end.y;
    }

    var svg = '<svg width="' + size + '" height="' + size + '" viewBox="0 0 ' + size + ' ' + size + '">';

    values.forEach(function(v, idx) {
      var radius = (size - stroke) / 2 - idx * (stroke + gap);
      var normalised = v.max > 0 ? Math.min(v.value / v.max, 1.0) : 0;
      var colour = v.colour || valueColour(normalised);
      var valueSweep = totalSweep * normalised;

      // Track
      svg += '<path d="' + arcPath(radius, startAngle, totalSweep) + '" fill="none" stroke="rgba(48,54,61,0.4)" stroke-width="' + stroke + '" stroke-linecap="round" />';
      // Value
      svg += '<path d="' + arcPath(radius, startAngle, valueSweep) + '" fill="none" stroke="' + colour + '" stroke-width="' + stroke + '" stroke-linecap="round"'
        + ' style="filter:drop-shadow(0 0 2px ' + colour + ');" />';
    });

    svg += '</svg>';
    el.innerHTML = svg;
  };

  // Mark module as loaded
  FLI.gauge._loaded = true;
  console.log('[FLI] gauge module loaded');
})();
