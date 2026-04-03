// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// fli-editable.js — FLI module: inline editing, keyboard navigation, cell editing
//
// Provides inline-edit capabilities for panels that inherit fli-editable.
// Used by: gsa-config (field editing), gsa-history (rollback interactions)
//
// Provisioning: this module is loaded on-demand when a panel with the
// fli-editable trait is activated. Panels start bare and FLI modules
// layer capabilities on top, following the same pattern as Groove
// (Burble/Vext) integration on base panels.
//
// API:
//   FLI.editable.init(container, options)        — enable inline editing
//   FLI.editable.makeEditable(element, options)  — make a single element editable
//   FLI.editable.onSave(callback)                — register save callback
//   FLI.editable.destroy(container)              — tear down inline editing

(function() {
  'use strict';

  window.FLI = window.FLI || {};
  window.FLI.editable = {};

  // =========================================================================
  // State
  // =========================================================================

  /** Active editors keyed by container ID. */
  var editors = {};

  /** Global save callback. */
  var saveCallback = null;

  /** Currently active inline editor element (only one at a time). */
  var activeEditor = null;

  // =========================================================================
  // Core: make elements inline-editable
  // =========================================================================

  /**
   * Initialise inline editing on all [data-editable] elements within a
   * container. Double-click to enter edit mode, Tab/Enter to commit,
   * Escape to cancel.
   *
   * @param {HTMLElement|string} container - Container element or ID
   * @param {object} options - Configuration:
   *   selector:    {string}  CSS selector for editable cells (default '[data-editable]')
   *   onSave:      {function} Called with (key, value, oldValue) when a field is saved
   *   onCancel:    {function} Called with (key, oldValue) when editing is cancelled
   *   validate:    {function} Called with (key, value) → true/false or error string
   *   commitOn:    {string}  'blur' | 'enter' | 'both' (default 'both')
   */
  FLI.editable.init = function(container, options) {
    var el = typeof container === 'string' ? document.getElementById(container) : container;
    if (!el) return;

    var opts = options || {};
    var selector = opts.selector || '[data-editable]';
    var commitOn = opts.commitOn || 'both';

    var id = el.id || 'fli-edit-' + Math.random().toString(36).substr(2, 6);
    el.id = id;

    editors[id] = {
      element: el,
      options: opts,
      selector: selector
    };

    // Attach double-click listener via delegation
    el.addEventListener('dblclick', function(e) {
      var target = e.target.closest(selector);
      if (target) {
        e.preventDefault();
        e.stopPropagation();
        enterEditMode(target, opts);
      }
    });

    // Also support single-click on elements with data-editable="click"
    el.addEventListener('click', function(e) {
      var target = e.target.closest(selector + '[data-editable="click"]');
      if (target) {
        e.preventDefault();
        enterEditMode(target, opts);
      }
    });
  };

  /**
   * Make a single element inline-editable.
   *
   * @param {HTMLElement} element - The element to make editable
   * @param {object} options - Same as init() options
   */
  FLI.editable.makeEditable = function(element, options) {
    if (!element) return;
    element.setAttribute('data-editable', 'true');
    element.style.cursor = 'pointer';
    element.title = element.title || 'Double-click to edit';

    element.addEventListener('dblclick', function(e) {
      e.preventDefault();
      e.stopPropagation();
      enterEditMode(element, options || {});
    });
  };

  /**
   * Register a global save callback.
   *
   * @param {function} callback - Called with (key, newValue, oldValue, element)
   */
  FLI.editable.onSave = function(callback) {
    saveCallback = callback;
  };

  /**
   * Destroy inline editing on a container.
   *
   * @param {HTMLElement|string} container - Container element or ID
   */
  FLI.editable.destroy = function(container) {
    var el = typeof container === 'string' ? document.getElementById(container) : container;
    if (!el) return;
    delete editors[el.id];
    // Cancel any active editor in this container
    if (activeEditor && el.contains(activeEditor.element)) {
      cancelEdit();
    }
  };

  // =========================================================================
  // Edit mode lifecycle
  // =========================================================================

  /**
   * Enter inline edit mode on an element. Replaces the element's content
   * with an appropriate input control and manages focus, commit, and cancel.
   *
   * @param {HTMLElement} element - The element to enter edit mode on
   * @param {object} opts - Configuration options
   */
  function enterEditMode(element, opts) {
    // Cancel any existing active editor first
    if (activeEditor) {
      commitEdit();
    }

    var key = element.dataset.editableKey || element.dataset.key || '';
    var type = element.dataset.editableType || 'text';
    var oldValue = element.dataset.editableValue !== undefined
      ? element.dataset.editableValue
      : element.textContent.trim();
    var enumOptions = element.dataset.editableOptions
      ? element.dataset.editableOptions.split(',')
      : null;
    var min = element.dataset.editableMin;
    var max = element.dataset.editableMax;

    // Store state — capture child nodes via deep clone so cancelEdit restores
    // the DOM directly (no innerHTML re-parse, no injection risk).
    activeEditor = {
      element: element,
      key: key,
      oldValue: oldValue,
      oldNodes: Array.from(element.childNodes).map(function(n) { return n.cloneNode(true); }),
      opts: opts
    };

    // Add editing class
    element.classList.add('fli-editing');

    // Create the appropriate input control
    var input;

    if (type === 'bool') {
      // Toggle immediately without an input
      var newVal = oldValue === 'true' ? 'false' : 'true';
      element.dataset.editableValue = newVal;
      commitEditDirect(key, newVal, oldValue, element, opts);
      activeEditor = null;
      return;
    }

    if (enumOptions) {
      input = document.createElement('select');
      input.className = 'fli-edit-input';
      enumOptions.forEach(function(opt) {
        var o = document.createElement('option');
        o.value = opt.trim();
        o.textContent = opt.trim();
        if (opt.trim() === oldValue) o.selected = true;
        input.appendChild(o);
      });
    } else if (type === 'number') {
      input = document.createElement('input');
      input.type = 'number';
      input.className = 'fli-edit-input';
      input.value = oldValue;
      if (min !== undefined) input.min = min;
      if (max !== undefined) input.max = max;
    } else {
      input = document.createElement('input');
      input.type = type === 'secret' ? 'password' : 'text';
      input.className = 'fli-edit-input';
      input.value = oldValue;
    }

    // Style the input to match the cell
    input.style.cssText = 'width:100%;padding:2px 6px;font-size:inherit;font-family:inherit;'
      + 'background:var(--bg-primary,#0d1117);color:var(--text-primary,#c9d1d9);'
      + 'border:1px solid var(--link-color,#58a6ff);border-radius:4px;outline:none;'
      + 'box-shadow:0 0 0 2px rgba(88,166,255,0.2);';

    // Replace content with input
    element.innerHTML = '';
    element.appendChild(input);
    input.focus();
    if (input.select) input.select();

    // Keyboard handlers
    input.addEventListener('keydown', function(e) {
      if (e.key === 'Enter') {
        e.preventDefault();
        commitEdit();
      } else if (e.key === 'Escape') {
        e.preventDefault();
        cancelEdit();
      } else if (e.key === 'Tab') {
        e.preventDefault();
        commitEdit();
        // Move to next editable element
        tabToNext(element, e.shiftKey);
      }
    });

    // Blur handler (commit on blur unless commitOn is 'enter')
    input.addEventListener('blur', function() {
      // Small delay to allow Tab to fire first
      setTimeout(function() {
        if (activeEditor && activeEditor.element === element) {
          if (opts.commitOn === 'enter') {
            cancelEdit();
          } else {
            commitEdit();
          }
        }
      }, 100);
    });
  }

  /**
   * Commit the current inline edit. Reads the input value, validates it,
   * and triggers the save callback.
   */
  function commitEdit() {
    if (!activeEditor) return;

    var element = activeEditor.element;
    var key = activeEditor.key;
    var oldValue = activeEditor.oldValue;
    var opts = activeEditor.opts;

    var input = element.querySelector('.fli-edit-input');
    var newValue = input ? input.value : oldValue;

    // Validate
    if (opts.validate) {
      var result = opts.validate(key, newValue);
      if (result !== true && result !== undefined) {
        // Validation failed — show error state briefly
        if (input) {
          input.style.borderColor = 'var(--danger-fg,#f85149)';
          input.style.boxShadow = '0 0 0 2px rgba(248,81,73,0.2)';
        }
        return;
      }
    }

    // Exit edit mode
    element.classList.remove('fli-editing');
    element.textContent = newValue;
    element.dataset.editableValue = newValue;

    // Notify
    commitEditDirect(key, newValue, oldValue, element, opts);

    activeEditor = null;
  }

  /**
   * Directly commit an edit without going through the input UI.
   * Used for immediate toggles (bools) and programmatic edits.
   */
  function commitEditDirect(key, newValue, oldValue, element, opts) {
    if (String(newValue) !== String(oldValue)) {
      if (opts.onSave) opts.onSave(key, newValue, oldValue, element);
      if (saveCallback) saveCallback(key, newValue, oldValue, element);

      // Visual feedback: brief highlight
      element.style.transition = 'background 0.3s ease';
      element.style.background = 'rgba(88,166,255,0.1)';
      setTimeout(function() {
        element.style.background = '';
      }, 600);
    }
  }

  /**
   * Cancel the current inline edit. Restores the original content.
   */
  function cancelEdit() {
    if (!activeEditor) return;

    var element = activeEditor.element;
    var opts = activeEditor.opts;

    element.classList.remove('fli-editing');
    element.replaceChildren.apply(element, activeEditor.oldNodes);

    if (opts.onCancel) opts.onCancel(activeEditor.key, activeEditor.oldValue);

    activeEditor = null;
  }

  /**
   * Tab to the next (or previous) editable element in the container.
   *
   * @param {HTMLElement} current - The current editable element
   * @param {boolean} reverse - Tab backwards if true
   */
  function tabToNext(current, reverse) {
    var container = current.closest('[id]');
    if (!container || !editors[container.id]) return;

    var selector = editors[container.id].selector;
    var all = Array.from(container.querySelectorAll(selector));
    var idx = all.indexOf(current);

    if (idx === -1) return;

    var nextIdx = reverse
      ? (idx - 1 + all.length) % all.length
      : (idx + 1) % all.length;

    var next = all[nextIdx];
    if (next) {
      enterEditMode(next, editors[container.id].options);
    }
  }

  // =========================================================================
  // Global keyboard shortcuts
  // =========================================================================

  // Escape to cancel any active editor
  document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape' && activeEditor) {
      cancelEdit();
    }
  });

  // Mark module as loaded
  FLI.editable._loaded = true;
  console.log('[FLI] editable module loaded');
})();
