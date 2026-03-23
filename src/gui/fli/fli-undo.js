// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// fli-undo.js — FLI module: undo/redo command stack
//
// Provides undo/redo capabilities for panels that inherit fli-undo.
// Used by: gsa-config (config field changes)
//
// Provisioning: loaded on-demand. Panels start bare; fli-undo layers
// undo tracking onto existing save flows. Binds Ctrl+Z / Ctrl+Shift+Z
// when the panel is active.
//
// API:
//   FLI.undo.push(action)     — push an undoable action
//   FLI.undo.undo()           — undo the last action
//   FLI.undo.redo()           — redo the last undone action
//   FLI.undo.clear()          — clear the entire stack
//   FLI.undo.canUndo()        — true if undo is possible
//   FLI.undo.canRedo()        — true if redo is possible
//   FLI.undo.onUpdate(cb)     — called when stack state changes
//   FLI.undo.history()        — get the full undo history

(function() {
  'use strict';

  window.FLI = window.FLI || {};
  window.FLI.undo = {};

  // =========================================================================
  // State
  // =========================================================================

  /** The undo stack: array of action objects. */
  var undoStack = [];

  /** The redo stack: array of action objects. */
  var redoStack = [];

  /** Maximum stack depth. */
  var MAX_DEPTH = 100;

  /** Update callback. */
  var updateCallback = null;

  /** Whether keyboard bindings are active. */
  var keyboardBound = false;

  // =========================================================================
  // Public API
  // =========================================================================

  /**
   * Push an undoable action onto the stack.
   * An action is an object with:
   *   type:        {string}   Action type name (e.g. 'field-change')
   *   description: {string}   Human-readable description
   *   undo:        {function} Function to call to undo this action
   *   redo:        {function} Function to call to redo this action
   *   data:        {object}   Optional data payload
   *
   * @param {object} action - The undoable action
   */
  FLI.undo.push = function(action) {
    if (!action || typeof action.undo !== 'function' || typeof action.redo !== 'function') {
      console.warn('[FLI.undo] Invalid action: must have undo() and redo() functions');
      return;
    }

    undoStack.push(action);

    // Clear redo stack on new action (linear history)
    redoStack = [];

    // Enforce max depth
    if (undoStack.length > MAX_DEPTH) {
      undoStack.shift();
    }

    notifyUpdate();
  };

  /**
   * Undo the last action. Moves it to the redo stack and calls action.undo().
   *
   * @returns {object|null} The undone action, or null if nothing to undo
   */
  FLI.undo.undo = function() {
    if (undoStack.length === 0) return null;

    var action = undoStack.pop();
    redoStack.push(action);

    try {
      action.undo();
    } catch (e) {
      console.error('[FLI.undo] Undo failed:', e);
    }

    notifyUpdate();

    // Toast feedback
    if (typeof showToast === 'function') {
      showToast('Undo: ' + (action.description || action.type), 'info', 2000);
    }

    return action;
  };

  /**
   * Redo the last undone action. Moves it back to the undo stack and calls
   * action.redo().
   *
   * @returns {object|null} The redone action, or null if nothing to redo
   */
  FLI.undo.redo = function() {
    if (redoStack.length === 0) return null;

    var action = redoStack.pop();
    undoStack.push(action);

    try {
      action.redo();
    } catch (e) {
      console.error('[FLI.undo] Redo failed:', e);
    }

    notifyUpdate();

    if (typeof showToast === 'function') {
      showToast('Redo: ' + (action.description || action.type), 'info', 2000);
    }

    return action;
  };

  /**
   * Clear the entire undo/redo history.
   */
  FLI.undo.clear = function() {
    undoStack = [];
    redoStack = [];
    notifyUpdate();
  };

  /**
   * @returns {boolean} True if there are actions to undo
   */
  FLI.undo.canUndo = function() {
    return undoStack.length > 0;
  };

  /**
   * @returns {boolean} True if there are actions to redo
   */
  FLI.undo.canRedo = function() {
    return redoStack.length > 0;
  };

  /**
   * Register a callback that fires whenever the stack state changes.
   * Useful for updating UI (enabling/disabling undo/redo buttons).
   *
   * @param {function} callback - Called with {canUndo, canRedo, undoCount, redoCount}
   */
  FLI.undo.onUpdate = function(callback) {
    updateCallback = callback;
  };

  /**
   * Get the full undo history as an array of action descriptions.
   *
   * @returns {Array<object>} Array of {type, description, timestamp} objects
   */
  FLI.undo.history = function() {
    return undoStack.map(function(a) {
      return {
        type: a.type,
        description: a.description || '',
        timestamp: a.timestamp || null
      };
    });
  };

  /**
   * Create a convenience field-change action for config editing.
   * Automatically builds the undo/redo functions from key + old/new values.
   *
   * @param {string} key - The config field key
   * @param {*} oldValue - The previous value
   * @param {*} newValue - The new value
   * @param {function} applyFn - Function to call with (key, value) to apply a change
   * @returns {object} An undoable action object
   */
  FLI.undo.fieldChange = function(key, oldValue, newValue, applyFn) {
    return {
      type: 'field-change',
      description: key + ': ' + String(oldValue) + ' → ' + String(newValue),
      timestamp: Date.now(),
      data: { key: key, oldValue: oldValue, newValue: newValue },
      undo: function() { applyFn(key, oldValue); },
      redo: function() { applyFn(key, newValue); }
    };
  };

  // =========================================================================
  // Keyboard bindings
  // =========================================================================

  /**
   * Bind Ctrl+Z (undo) and Ctrl+Shift+Z (redo) keyboard shortcuts.
   * Called automatically when the module loads.
   */
  function bindKeyboard() {
    if (keyboardBound) return;

    document.addEventListener('keydown', function(e) {
      // Only act when not in an input/textarea/select
      var tag = document.activeElement ? document.activeElement.tagName : '';
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;

      if ((e.ctrlKey || e.metaKey) && e.key === 'z') {
        e.preventDefault();
        if (e.shiftKey) {
          FLI.undo.redo();
        } else {
          FLI.undo.undo();
        }
      }
    });

    keyboardBound = true;
  }

  // =========================================================================
  // Internal
  // =========================================================================

  /** Notify the update callback of stack state changes. */
  function notifyUpdate() {
    if (updateCallback) {
      updateCallback({
        canUndo: undoStack.length > 0,
        canRedo: redoStack.length > 0,
        undoCount: undoStack.length,
        redoCount: redoStack.length
      });
    }
  }

  // Auto-bind keyboard on load
  bindKeyboard();

  // Mark module as loaded
  FLI.undo._loaded = true;
  console.log('[FLI] undo module loaded');
})();
