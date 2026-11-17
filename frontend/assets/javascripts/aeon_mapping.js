/**
 * Aeon Mapping Rules — Staff UI JavaScript
 *
 * Vanilla JS with fetch() — no additional dependencies.
 * Drag-to-reorder uses HTML5 Drag & Drop with keyboard (Up/Down button) fallback.
 */
(function () {
  'use strict';

  // ---------------------------------------------------------------------------
  // Utilities
  // ---------------------------------------------------------------------------

  function debounce(fn, ms) {
    var timer;
    return function () {
      var args = arguments;
      var ctx  = this;
      clearTimeout(timer);
      timer = setTimeout(function () { fn.apply(ctx, args); }, ms);
    };
  }

  function getCsrfToken() {
    var meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.getAttribute('content') : '';
  }

  function postJSON(url, body) {
    return fetch(url, {
      method:  'POST',
      headers: {
        'Content-Type':  'application/json',
        'Accept':        'application/json',
        'X-CSRF-Token':  getCsrfToken()
      },
      body: JSON.stringify(body)
    }).then(function (r) { return r.json(); });
  }

  function getJSON(url) {
    return fetch(url, {
      headers: { 'Accept': 'application/json', 'X-CSRF-Token': getCsrfToken() }
    }).then(function (r) { return r.json(); });
  }

  // Persistent page-level message in the area above the rules table.
  // Confirmations and errors go here rather than into transient toasts —
  // the bottom-corner toasts proved easy to miss during staff testing.
  function showPageMessage(msg, type) {
    var container = document.getElementById('aeon-mapping-messages');
    if (!container) {
      showToast(msg);
      return;
    }

    container.innerHTML = '';
    var alert = document.createElement('div');
    alert.className = 'alert alert-dismissible ' +
      (type === 'error' ? 'alert-danger' : 'alert-success');
    alert.setAttribute('role', type === 'error' ? 'alert' : 'status');
    alert.textContent = msg;

    var close = document.createElement('button');
    close.type = 'button';
    close.className = 'close';
    close.setAttribute('aria-label', 'Close');
    close.innerHTML = '<span aria-hidden="true">&times;</span>';
    close.addEventListener('click', function () {
      if (alert.parentNode) alert.parentNode.removeChild(alert);
    });
    alert.appendChild(close);

    container.appendChild(alert);
    container.scrollIntoView({ block: 'nearest' });
  }

  // Shows the save confirmation parked by submitRuleForm before its reload.
  function showPendingSaveMessage() {
    var raw;
    try {
      raw = sessionStorage.getItem('aeonMappingSavedRule');
      if (raw) sessionStorage.removeItem('aeonMappingSavedRule');
    } catch (e) { return; }
    if (!raw) return;

    var saved;
    try { saved = JSON.parse(raw); } catch (e) { return; }

    var verb = saved.action === 'created'
      ? getI18n('rule_created_toast', 'Rule created')
      : getI18n('rule_updated_toast', 'Rule updated');
    showPageMessage(saved.field ? (verb + ': ' + saved.field) : (verb + '.'), 'success');
  }

  function showToast(msg) {
    var toast = document.createElement('div');
    toast.className = 'aeon-copy-toast';
    toast.textContent = msg;
    toast.setAttribute('role', 'status');
    toast.setAttribute('aria-live', 'polite');
    document.body.appendChild(toast);
    setTimeout(function () {
      if (toast.parentNode) toast.parentNode.removeChild(toast);
    }, 2800);
  }

  // Copy text to clipboard with a graceful fallback path.
  //
  // 1. Try the modern async Clipboard API (works on https/localhost when the
  //    user has actually clicked or pressed a key).
  // 2. If that rejects (permission denied, insecure context, headless
  //    browser, etc.), fall back to the legacy textarea + execCommand('copy')
  //    technique, which has broader compatibility.
  // 3. If both fail, reject so the caller can surface the text to the user
  //    for manual copy.
  function copyTextRobust(text) {
    return new Promise(function (resolve, reject) {
      var modern = navigator.clipboard && navigator.clipboard.writeText;
      if (modern) {
        navigator.clipboard.writeText(text).then(
          function () { resolve('clipboard'); },
          function () { tryExecCommand(); }
        );
      } else {
        tryExecCommand();
      }

      function tryExecCommand() {
        try {
          var ta = document.createElement('textarea');
          ta.value = text;
          // Off-screen but in-DOM (required for selection)
          ta.setAttribute('readonly', '');
          ta.style.position = 'fixed';
          ta.style.left = '-9999px';
          ta.style.top = '0';
          document.body.appendChild(ta);
          ta.select();
          ta.setSelectionRange(0, text.length);
          var ok = document.execCommand('copy');
          document.body.removeChild(ta);
          if (ok) resolve('execCommand');
          else reject(new Error('execCommand returned false'));
        } catch (e) {
          reject(e);
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Page-level state
  // ---------------------------------------------------------------------------

  var pageState = {
    repoId:      null,
    recordType:  null,
    scope:       'repo',   // 'global' or 'repo'
    consumer:    null,     // selected consumer key — sent with every rule/preview call
    previewJson: null,     // last loaded raw record JSON
    rulesDirty:  false,    // in-flight rule modal has unsaved changes
    extractors:  [],       // cached predefined extractors list
    modalRuleId: null,     // null = new rule
    modalOriginalField: null // Aeon field name as loaded into the edit modal
  };

  // ---------------------------------------------------------------------------
  // Scope helpers
  // ---------------------------------------------------------------------------

  // Returns the frontend base path for rule API calls depending on scope.
  // Global scope → /plugins/aeon_mapping/global_rules
  // Repo scope   → /plugins/aeon_mapping/rules
  function rulesApiBase() {
    return pageState.scope === 'global'
      ? '/plugins/aeon_mapping/global_rules'
      : '/plugins/aeon_mapping/rules';
  }

  // Returns the frontend preview endpoint path depending on scope.
  function previewApiPath() {
    return pageState.scope === 'global'
      ? '/plugins/aeon_mapping/global_preview'
      : '/plugins/aeon_mapping/preview';
  }

  // Returns query-string suffix with repo_id only when in repo scope.
  function repoQs() {
    return pageState.scope === 'global' ? '' : ('?repo_id=' + pageState.repoId);
  }

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  document.addEventListener('DOMContentLoaded', function () {
    var page = document.getElementById('aeon-mapping-page');
    if (!page) return;

    pageState.repoId     = page.getAttribute('data-repo-id');
    pageState.recordType = page.getAttribute('data-record-type');
    pageState.scope      = page.getAttribute('data-scope') || 'repo';
    pageState.consumer   = page.getAttribute('data-consumer') || '';

    initRulesTable();
    initAddRuleButton();
    initRuleModal();
    initPreviewPanel();
    initToggleEnabledHandlers();
    initConsumerControls(page);
    showPendingSaveMessage();

    // Pre-fetch extractors list for current record type
    fetchExtractors(pageState.recordType);
  });

  // ---------------------------------------------------------------------------
  // Rules table — drag to reorder + keyboard Up/Down
  // ---------------------------------------------------------------------------

  // In a repository view the defaults block is fixed: consumer-default rows,
  // and the overrides that shadow one, keep the defaults' order (change it
  // under Consumer Defaults). Only repository-only rules reorder, among
  // themselves, below that block — so those rows are the only drag sources
  // AND the only drop targets.
  function rowOrderLocked(row) {
    if (pageState.scope === 'global') return false;
    if (row.getAttribute('data-origin') === 'global') return true;
    var edit = row.querySelector('.rule-edit-btn');
    return !!(edit && edit.getAttribute('data-has-default') === 'true');
  }

  function initRulesTable() {
    var tbody = document.getElementById('rules-tbody');
    if (!tbody) return;

    // HTML5 drag-to-reorder
    var dragSrc = null;

    tbody.addEventListener('dragstart', function (e) {
      var row = e.target.closest('.aeon-rule-row');
      if (!row || rowOrderLocked(row)) return;
      dragSrc = row;
      row.classList.add('dragging');
      e.dataTransfer.effectAllowed = 'move';
    });

    tbody.addEventListener('dragover', function (e) {
      e.preventDefault();
      e.dataTransfer.dropEffect = 'move';
      var row = e.target.closest('.aeon-rule-row');
      if (row && row !== dragSrc && !rowOrderLocked(row)) {
        clearDragOver(tbody);
        row.classList.add('drag-over');
      }
    });

    tbody.addEventListener('dragleave', function (e) {
      var row = e.target.closest('.aeon-rule-row');
      if (row) row.classList.remove('drag-over');
    });

    tbody.addEventListener('drop', function (e) {
      e.preventDefault();
      clearDragOver(tbody);
      var target = e.target.closest('.aeon-rule-row');
      if (!target || !dragSrc || target === dragSrc || rowOrderLocked(target)) return;

      var rows = Array.from(tbody.querySelectorAll('.aeon-rule-row'));
      var srcIdx = rows.indexOf(dragSrc);
      var tgtIdx = rows.indexOf(target);

      if (srcIdx < tgtIdx) {
        target.parentNode.insertBefore(dragSrc, target.nextSibling);
      } else {
        target.parentNode.insertBefore(dragSrc, target);
      }

      saveRowOrder();
    });

    tbody.addEventListener('dragend', function () {
      if (dragSrc) { dragSrc.classList.remove('dragging'); dragSrc = null; }
      clearDragOver(tbody);
    });

    // Make rows draggable (except locked default rows in repo view)
    Array.from(tbody.querySelectorAll('.aeon-rule-row')).forEach(function (row) {
      if (rowOrderLocked(row)) {
        var handle = row.querySelector('.aeon-drag-handle');
        if (handle) handle.style.visibility = 'hidden';
        Array.from(row.querySelectorAll('.rule-move-up, .rule-move-down')).forEach(function (b) {
          b.disabled = true;
        });
        row.title = getI18n('reorder_default_locked',
          'Rules from the application defaults keep the defaults\' order here. Repository rules reorder below them.');
        return;
      }
      row.setAttribute('draggable', 'true');
    });

    // Keyboard Up/Down buttons (hidden visually but reachable by keyboard)
    tbody.addEventListener('click', function (e) {
      var btn = e.target.closest('.rule-move-up, .rule-move-down');
      if (!btn) return;

      var row  = btn.closest('.aeon-rule-row');
      if (rowOrderLocked(row)) return;
      var rows = Array.from(tbody.querySelectorAll('.aeon-rule-row'));
      var idx  = rows.indexOf(row);

      if (btn.classList.contains('rule-move-up') && idx > 0 && !rowOrderLocked(rows[idx - 1])) {
        tbody.insertBefore(row, rows[idx - 1]);
        saveRowOrder();
        btn.focus(); // keep focus on the button
      } else if (btn.classList.contains('rule-move-down') && idx < rows.length - 1 && !rowOrderLocked(rows[idx + 1])) {
        tbody.insertBefore(rows[idx + 1], row);
        saveRowOrder();
        btn.focus();
      }
    });

    // Arrow-key support on drag handle
    tbody.addEventListener('keydown', function (e) {
      if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return;
      var handle = e.target.closest('.aeon-drag-handle');
      if (!handle) return;
      e.preventDefault();

      var row  = handle.closest('.aeon-rule-row');
      if (rowOrderLocked(row)) return;
      var rows = Array.from(tbody.querySelectorAll('.aeon-rule-row'));
      var idx  = rows.indexOf(row);

      if (e.key === 'ArrowUp' && idx > 0 && !rowOrderLocked(rows[idx - 1])) {
        tbody.insertBefore(row, rows[idx - 1]);
        handle.focus();
        saveRowOrder();
      } else if (e.key === 'ArrowDown' && idx < rows.length - 1 && !rowOrderLocked(rows[idx + 1])) {
        tbody.insertBefore(rows[idx + 1], row);
        handle.focus();
        saveRowOrder();
      }
    });

    // Make drag handles keyboard-focusable (locked rows keep theirs inert)
    Array.from(tbody.querySelectorAll('.aeon-drag-handle')).forEach(function (h) {
      if (rowOrderLocked(h.closest('.aeon-rule-row'))) return;
      h.setAttribute('tabindex', '0');
      h.setAttribute('role', 'button');
    });

    // Edit buttons
    tbody.addEventListener('click', function (e) {
      var btn = e.target.closest('.rule-edit-btn');
      if (!btn) return;
      var ruleId     = btn.getAttribute('data-rule-id');
      var repoId     = btn.getAttribute('data-repo-id');
      var recordType = btn.getAttribute('data-record-type');
      openEditModal(ruleId, repoId, recordType, btn);
    });

  }

  // Bound outside initRulesTable on purpose: that function quits early when
  // #rules-tbody is absent, and the table only renders when rules exist.
  // Add Rule must still work on an empty list — the state every new
  // application starts in.
  function initAddRuleButton() {
    var addBtn = document.getElementById('add-rule-btn');
    if (!addBtn) return;
    addBtn.addEventListener('click', function () {
      openAddModal(
        addBtn.getAttribute('data-repo-id'),
        addBtn.getAttribute('data-record-type'),
        addBtn
      );
    });
  }

  function clearDragOver(tbody) {
    Array.from(tbody.querySelectorAll('.drag-over')).forEach(function (r) {
      r.classList.remove('drag-over');
    });
  }

  function saveRowOrder() {
    var tbody = document.getElementById('rules-tbody');
    if (!tbody) return;

    var ids = Array.from(tbody.querySelectorAll('.aeon-rule-row'))
      .map(function (r) { return parseInt(r.getAttribute('data-rule-id'), 10); });

    var reorderUrl = pageState.scope === 'global'
      ? '/plugins/aeon_mapping/global_rules/reorder'
      : ('/plugins/aeon_mapping/reorder?repo_id=' + pageState.repoId);

    postJSON(
      reorderUrl,
      { consumer: pageState.consumer, record_type: pageState.recordType, rule_ids: ids }
    ).catch(function (err) {
      console.error('AeonMapping: reorder error', err);
    });
  }

  // ---------------------------------------------------------------------------
  // Enable/disable toggle
  // ---------------------------------------------------------------------------

  function initToggleEnabledHandlers() {
    document.addEventListener('change', function (e) {
      var cb = e.target.closest('.rule-enabled-toggle');
      if (!cb) return;

      var ruleId     = cb.getAttribute('data-rule-id');
      var repoId     = cb.getAttribute('data-repo-id');
      var recordType = cb.getAttribute('data-record-type');
      var enabled    = cb.checked;

      var toggleUrl = pageState.scope === 'global'
        ? ('/plugins/aeon_mapping/global_rules/' + ruleId)
        : ('/plugins/aeon_mapping/rules/' + ruleId + '?repo_id=' + repoId);

      postJSON(
        toggleUrl,
        { consumer: pageState.consumer, enabled: enabled, record_type: recordType }
      ).then(function (result) {
        if (result.error || result.errors) {
          cb.checked = !enabled; // revert
          showPageMessage(formatRuleErrors(result).join('. '), 'error');
          console.error('AeonMapping: toggle error', result.error || result.errors);
        }
      }).catch(function (err) {
        cb.checked = !enabled;
        showPageMessage('Error: ' + err.message, 'error');
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Consumer controls — add / rename / delete the selected consumer
  // ---------------------------------------------------------------------------

  function initConsumerControls(page) {
    var modal = document.getElementById('consumer-modal');
    var form  = document.getElementById('consumer-form');
    if (!modal || !form) return;

    var consumerId    = page.getAttribute('data-consumer-id');
    var consumerLabel = page.getAttribute('data-consumer-label') || '';
    var ruleCount     = page.getAttribute('data-consumer-rule-count') || '0';
    var modalMode     = 'add';

    function showConsumerModal(mode) {
      modalMode = mode;
      var titleEl = document.getElementById('consumer-modal-title');
      var keyInp  = document.getElementById('consumer-key');
      var errEl   = document.getElementById('consumer-form-errors');

      form.reset();
      if (errEl) { errEl.classList.add('d-none'); errEl.innerHTML = ''; }

      if (mode === 'rename') {
        titleEl.textContent = titleEl.getAttribute('data-rename-title');
        keyInp.value    = pageState.consumer;
        keyInp.disabled = true;
        document.getElementById('consumer-label').value = consumerLabel;
      } else {
        titleEl.textContent = titleEl.getAttribute('data-add-title');
        keyInp.disabled = false;
      }

      if (window.jQuery && window.jQuery.fn && window.jQuery.fn.modal) {
        window.jQuery(modal).modal('show');
      } else {
        modal.style.display = 'block';
        modal.classList.add('show');
      }
    }

    var addBtn = document.getElementById('add-consumer-btn');
    if (addBtn) addBtn.addEventListener('click', function () { showConsumerModal('add'); });

    var renameBtn = document.getElementById('rename-consumer-btn');
    if (renameBtn) renameBtn.addEventListener('click', function () { showConsumerModal('rename'); });

    var deleteBtn = document.getElementById('delete-consumer-btn');
    if (deleteBtn) {
      deleteBtn.addEventListener('click', function () {
        var msg = getI18n('consumer_confirm_delete',
                          'Delete "%{label}" and all of its %{count} mapping rules? This cannot be undone.')
          .replace('%{label}', consumerLabel)
          .replace('%{count}', ruleCount);
        if (!confirm(msg)) return;

        postJSON('/plugins/aeon_mapping/consumers/' + consumerId + '/delete', {})
          .then(function (result) {
            if (result.error) {
              showPageMessage(result.error, 'error');
              return;
            }
            // Land back on the default consumer
            window.location.href = '/plugins/aeon_mapping?record_type=' +
              encodeURIComponent(pageState.recordType);
          })
          .catch(function (err) { showPageMessage('Error: ' + err.message, 'error'); });
      });
    }

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var key   = document.getElementById('consumer-key').value.trim();
      var label = document.getElementById('consumer-label').value.trim();
      var errEl = document.getElementById('consumer-form-errors');

      var url  = modalMode === 'rename'
        ? ('/plugins/aeon_mapping/consumers/' + consumerId)
        : '/plugins/aeon_mapping/consumers';
      var body = modalMode === 'rename' ? { label: label } : { key: key, label: label };

      postJSON(url, body)
        .then(function (result) {
          if (result.error || result.errors) {
            renderRuleFormErrors(errEl, result);
            return;
          }
          // Reload scoped to the created/renamed consumer
          var targetKey = modalMode === 'rename' ? pageState.consumer : result.key;
          window.location.href = '/plugins/aeon_mapping?consumer=' +
            encodeURIComponent(targetKey) +
            '&record_type=' + encodeURIComponent(pageState.recordType);
        })
        .catch(function (err) {
          renderRuleFormErrors(errEl, { error: 'Error: ' + err.message });
        });
    });
  }

  // ---------------------------------------------------------------------------
  // Rule modal — open for add / edit
  // ---------------------------------------------------------------------------

  var _triggerBtn = null; // element that opened the modal (for focus return)

  function openAddModal(repoId, recordType, triggerBtn) {
    _triggerBtn = triggerBtn || null;
    pageState.modalRuleId = null;
    resetModal(repoId, recordType);
    document.getElementById('modal-title-text').textContent =
      getI18n('add_rule', 'Add Rule');
    showModal();
  }

  function openEditModal(ruleId, repoId, recordType, triggerBtn) {
    _triggerBtn = triggerBtn || null;
    pageState.modalRuleId = ruleId;

    var fetchUrl = pageState.scope === 'global'
      ? ('/plugins/aeon_mapping/global_rules/' + ruleId)
      : ('/plugins/aeon_mapping/rules/' + ruleId + '?repo_id=' + repoId);

    getJSON(fetchUrl)
      .then(function (rule) {
        resetModal(repoId, recordType);
        populateModal(rule);
        document.getElementById('modal-title-text').textContent =
          getI18n('edit', 'Edit') + ': ' + rule.aeon_field_name;

        // The single-rule fetch has no origin/has_global_default — the list
        // endpoint adds those — so the row's Edit button carries them as
        // data attributes.
        var origin     = triggerBtn ? triggerBtn.getAttribute('data-origin') : null;
        var hasDefault = triggerBtn && triggerBtn.getAttribute('data-has-default') === 'true';

        var modal = document.getElementById('rule-form-modal');
        var isGlobalModal = modal && modal.getAttribute('data-global-scope') === 'true';

        // Show the consumer-default notice only when in repo scope and
        // editing a default. In the defaults scope the user edits defaults
        // directly, so the notice is irrelevant.
        if (!isGlobalModal && origin === 'global') {
          var notice = document.getElementById('global-rule-notice');
          if (notice) notice.classList.remove('d-none');
        }

        // Overrides shadow their default by Aeon field name, so a rename
        // from repo scope would resurface the default next to the renamed
        // rule. Lock the field for defaults and for overrides that shadow
        // one; a different Aeon field means a new rule. The backend
        // enforces the same restriction.
        if (!isGlobalModal && (origin === 'global' || hasDefault)) {
          var fieldInp = document.getElementById('rule-aeon-field-name');
          if (fieldInp) {
            fieldInp.readOnly = true;
            fieldInp.title = getI18n('aeon_field_locked',
              'Overrides keep the default\'s Aeon field. To map a different field, add a new rule.');
          }
        }

        showModal();
      })
      .catch(function (err) {
        console.error('AeonMapping: failed to load rule', ruleId, err);
      });
  }

  function showModal() {
    var modal = document.getElementById('rule-form-modal');
    if (!modal) return;
    // Use Bootstrap's modal if available, otherwise toggle manually
    if (window.jQuery && window.jQuery.fn && window.jQuery.fn.modal) {
      window.jQuery(modal).modal('show');
    } else {
      modal.style.display = 'block';
      modal.classList.add('show');
      document.body.classList.add('modal-open');
    }

    // Focus first input after show
    setTimeout(function () {
      var first = modal.querySelector('input, select, textarea');
      if (first) first.focus();
    }, 150);
  }

  function hideModal() {
    var modal = document.getElementById('rule-form-modal');
    if (!modal) return;
    if (window.jQuery && window.jQuery.fn && window.jQuery.fn.modal) {
      window.jQuery(modal).modal('hide');
    } else {
      modal.style.display = 'none';
      modal.classList.remove('show');
      document.body.classList.remove('modal-open');
    }
    // Return focus to trigger button
    if (_triggerBtn) {
      _triggerBtn.focus();
      _triggerBtn = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Rule modal init
  // ---------------------------------------------------------------------------

  function initRuleModal() {
    var modal = document.getElementById('rule-form-modal');
    if (!modal) return;

    var form = document.getElementById('rule-form');
    if (!form) return;

    // Transformation type change
    var ttSelect = document.getElementById('rule-transformation-type');
    if (ttSelect) {
      ttSelect.addEventListener('change', function () {
        updateTransformationOptsVisibility(this.value);
        updateSourceRows();
        markDirty();
      });
    }

    // Add source button
    var addSourceBtn = document.getElementById('add-source-btn');
    if (addSourceBtn) {
      addSourceBtn.addEventListener('click', function () {
        addSourceRow({});
        updateSourceRows();  // refresh button visibility (e.g. show remove btn now that we have >1 rows)
        markDirty();
      });
    }

    // Remove source (delegated)
    document.getElementById('sources-list').addEventListener('click', function (e) {
      var btn = e.target.closest('.remove-source-btn');
      if (!btn) return;
      var row = btn.closest('.source-row');
      if (row) {
        row.parentNode.removeChild(row);
        reindexSources();
        updateSourceRows();  // refresh button visibility after row count change
        updateTemplateHints();
        markDirty();
      }
    });

    // Source type toggle — handle clicks on the label OR change events on the
    // radio. Bootstrap 4's `data-toggle="buttons"` swallows the radio's change
    // event under certain conditions, so relying on `change` alone meant the
    // JSONPath input never appeared when users clicked the toggle. Listening
    // for clicks on the label (which Bootstrap does NOT swallow) is the
    // reliable trigger.
    var sourcesList = document.getElementById('sources-list');
    sourcesList.addEventListener('change', function (e) {
      if (!e.target.name || e.target.name !== 'source_types[]') return;
      handleSourceTypeChange(e.target);
    });
    sourcesList.addEventListener('click', function (e) {
      // Find the radio inside the clicked label
      var label = e.target.closest('.source-type-toggle label');
      if (!label) return;
      var radio = label.querySelector('input[name="source_types[]"]');
      if (!radio) return;
      radio.checked = true;
      // Toggle .active class on labels manually so we don't depend on
      // Bootstrap's data-toggle="buttons" behavior for this critical UI.
      label.parentNode.querySelectorAll('label').forEach(function (l) {
        l.classList.toggle('active', l === label);
      });
      handleSourceTypeChange(radio);
    });

    function handleSourceTypeChange(radio) {
      var row  = radio.closest('.source-row');
      var type = radio.value;
      if (!row) return;
      switchSourceType(row, type);
      markDirty();
    }

    // Template string change — update placeholder hints
    var templateInput = document.getElementById('rule-template');
    if (templateInput) {
      templateInput.addEventListener('input', debounce(updateTemplateHints, 200));
    }

    // Regex pattern — live test
    var patternInput = document.getElementById('rule-pattern');
    if (patternInput) {
      patternInput.addEventListener('input', debounce(liveTestRegex, 300));
    }

    // Form submission
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      submitRuleForm();
    });

    // Close / cancel — warn if dirty
    var closeBtn = document.getElementById('rule-modal-close');
    var cancelBtn = document.getElementById('rule-modal-cancel');

    function handleClose() {
      if (pageState.rulesDirty) {
        if (!confirm(getI18n('unsaved_changes', 'You have unsaved changes. Leave?'))) return;
      }
      pageState.rulesDirty = false;
      hideModal();
    }

    if (closeBtn)  closeBtn.addEventListener('click',  handleClose);
    if (cancelBtn) cancelBtn.addEventListener('click', handleClose);

    // Escape key
    document.addEventListener('keydown', function (e) {
      if (e.key !== 'Escape') return;
      var m = document.getElementById('rule-form-modal');
      if (m && m.classList.contains('show')) handleClose();
    });

    // Mark dirty on any input change in the form
    form.addEventListener('input',  function () { markDirty(); });
    form.addEventListener('change', function () { markDirty(); });
  }

  // Tracks dirty state only — the user is warned on actual leave attempts
  // (the confirm() in the modal's close handlers and the beforeunload
  // handler), never with a persistent in-form banner.
  function markDirty() {
    pageState.rulesDirty = true;
  }

  // ---------------------------------------------------------------------------
  // Modal reset / populate
  // ---------------------------------------------------------------------------

  function resetModal(repoId, recordType) {
    var form = document.getElementById('rule-form');
    if (!form) return;

    form.reset();
    pageState.rulesDirty = false;
    pageState.modalOriginalField = null;

    var notice = document.getElementById('global-rule-notice');
    if (notice) notice.classList.add('d-none');

    var errors = document.getElementById('rule-form-errors');
    if (errors) { errors.classList.add('d-none'); errors.textContent = ''; }

    document.getElementById('rule-form-rule-id').value   = '';
    document.getElementById('rule-form-repo-id').value   = repoId;
    document.getElementById('rule-form-record-type').value = recordType;

    // Unlock the Aeon field input — openEditModal re-locks it when the rule
    // being edited is (or shadows) a consumer default.
    var fieldInp = document.getElementById('rule-aeon-field-name');
    if (fieldInp) {
      fieldInp.readOnly = false;
      fieldInp.removeAttribute('title');
    }

    var csrfMeta = document.querySelector('meta[name="csrf-token"]');
    if (csrfMeta) document.getElementById('rule-form-csrf').value = csrfMeta.getAttribute('content');

    document.getElementById('sources-list').innerHTML = '';

    updateTransformationOptsVisibility('simple');

    // Default: one source row
    addSourceRow({});
    updateSourceRows();  // hide add/remove buttons for the default Simple type
  }

  function populateModal(rule) {
    document.getElementById('rule-form-rule-id').value = rule.id;
    document.getElementById('rule-aeon-field-name').value = rule.aeon_field_name || '';
    pageState.modalOriginalField = rule.aeon_field_name || null;

    var ttSelect = document.getElementById('rule-transformation-type');
    if (ttSelect) ttSelect.value = rule.transformation_type || 'simple';
    updateTransformationOptsVisibility(rule.transformation_type || 'simple');

    var enabledCb = document.getElementById('rule-enabled');
    if (enabledCb) enabledCb.checked = rule.enabled !== false;

    // Transformation options
    var opts = rule.transformation_options || {};
    var delimInp = document.getElementById('rule-delimiter');
    if (delimInp) delimInp.value = opts.delimiter || '';

    var tmplInp = document.getElementById('rule-template');
    if (tmplInp) tmplInp.value = opts.template || '';

    var patInp = document.getElementById('rule-pattern');
    if (patInp) patInp.value = opts.pattern || '';

    var maxLenInp = document.getElementById('rule-max-length');
    if (maxLenInp) maxLenInp.value = (opts.max_length != null) ? opts.max_length : '';

    // Sources
    var srcList = document.getElementById('sources-list');
    srcList.innerHTML = '';
    (rule.sources || []).forEach(function (src) { addSourceRow(src); });
    if (!(rule.sources && rule.sources.length)) addSourceRow({});

    updateSourceRows();    // ensure add/remove button visibility matches transformation type
    updateTemplateHints();
  }

  // ---------------------------------------------------------------------------
  // Transformation options visibility
  // ---------------------------------------------------------------------------

  function updateTransformationOptsVisibility(type) {
    var panels = document.querySelectorAll('.transformation-opts');
    panels.forEach(function (p) { p.classList.add('d-none'); });

    var target = document.getElementById('opts-' + type);
    if (target) target.classList.remove('d-none');

    // Update help text — read from the selected option's data-help attribute
    // (rendered server-side from the i18n table) rather than a client-side
    // i18n lookup.
    var helpEl = document.getElementById('transformation-type-help');
    var ttSelect = document.getElementById('rule-transformation-type');
    if (helpEl && ttSelect) {
      var selectedOpt = ttSelect.querySelector('option[value="' + type + '"]');
      helpEl.textContent = selectedOpt ? (selectedOpt.getAttribute('data-help') || '') : '';
    }
  }

  // Transformation types the engine evaluates against a SINGLE source only.
  // - simple:  uses sources.first
  // - extract: applies the regex to sources.first
  // concat / conditional / template all consume every source.
  var SINGLE_SOURCE_TYPES = ['simple', 'extract'];

  function updateSourceRows() {
    var type = document.getElementById('rule-transformation-type');
    if (!type) return;
    var isTemplate     = type.value === 'template';
    var isSingleSource = SINGLE_SOURCE_TYPES.indexOf(type.value) !== -1;

    document.querySelectorAll('.source-placeholder-group').forEach(function (g) {
      if (isTemplate) g.classList.remove('d-none');
      else            g.classList.add('d-none');
    });

    // Single-source transformations (Simple, Extract): exactly one source —
    // hide the add/remove controls and trim any extra rows left over from a
    // previous multi-source transformation type. The engine ignores sources
    // beyond the first for these types, so allowing more in the UI would be
    // silent data loss.
    var addBtn = document.getElementById('add-source-btn');
    if (addBtn) addBtn.classList.toggle('d-none', isSingleSource);

    var rows = document.querySelectorAll('#sources-list .source-row');
    rows.forEach(function (row) {
      var removeBtn = row.querySelector('.remove-source-btn');
      if (!removeBtn) return;
      // Hide remove for single-source types; also hide for multi-source types
      // when only one row exists (otherwise removing the last source leaves
      // the rule with no source at all).
      var hideRemove = isSingleSource || rows.length === 1;
      removeBtn.classList.toggle('d-none', hideRemove);
    });

    if (isSingleSource && rows.length > 1) {
      // Drop extras silently — switching to a single-source type implies
      // "just use one source".
      for (var i = rows.length - 1; i >= 1; i--) {
        rows[i].parentNode.removeChild(rows[i]);
      }
      reindexSources();
    }
  }

  // ---------------------------------------------------------------------------
  // Source rows
  // ---------------------------------------------------------------------------

  var sourceCounter = 0;

  function addSourceRow(src) {
    var tpl = document.getElementById('source-row-template');
    if (!tpl) return;

    var idx = sourceCounter++;
    var html = tpl.innerHTML
      .replace(/__IDX__/g, idx)
      .replace(/__IDX_HUMAN__/g, idx + 1);

    var div = document.createElement('div');
    div.innerHTML = html;

    var row = div.firstElementChild;
    document.getElementById('sources-list').appendChild(row);

    // Set source type
    var stype = src.source_type || 'predefined';
    var radio = row.querySelector('input[value="' + stype + '"]');
    if (radio) {
      radio.checked = true;
      var label = radio.closest('label');
      if (label) {
        label.classList.add('active');
        var sibling = label.parentNode.querySelector('label:not(.active)');
        if (sibling) sibling.classList.remove('active');
      }
    }

    switchSourceType(row, stype);

    // Set value
    if (stype === 'predefined') {
      var hiddenInput = row.querySelector('.extractor-value-input');
      var searchInput = row.querySelector('.extractor-search-input');
      if (hiddenInput) hiddenInput.value = src.source_value || '';
      if (searchInput) searchInput.value = src.source_value || '';
      initExtractorPicker(row, src.source_value);
    } else {
      var jpInput = row.querySelector('.jsonpath-input');
      if (jpInput) jpInput.value = src.source_value || '';
    }

    // Placeholder
    var phInput = row.querySelector('[name="placeholders[]"]');
    if (phInput) phInput.value = src.placeholder || '';

    // Show placeholder group if template
    var ttSelect = document.getElementById('rule-transformation-type');
    if (ttSelect && ttSelect.value === 'template') {
      var phGroup = row.querySelector('.source-placeholder-group');
      if (phGroup) phGroup.classList.remove('d-none');
    }

    // Wire up JSONPath debounced validation
    var jpInp = row.querySelector('.jsonpath-input');
    if (jpInp) {
      jpInp.addEventListener('input', debounce(function () {
        validateAndPreviewJsonPath(jpInp);
        triggerInFlightPreview();
      }, 300));
    }
  }

  function switchSourceType(row, type) {
    var predefined = row.querySelector('.source-predefined-input');
    var jsonpath   = row.querySelector('.source-jsonpath-input');
    if (!predefined || !jsonpath) return;

    if (type === 'predefined') {
      predefined.classList.remove('d-none');
      jsonpath.classList.add('d-none');
      // Clear jsonpath name so only predefined value submits
      var jpInp = row.querySelector('.jsonpath-input');
      if (jpInp) jpInp.removeAttribute('name');
      var hiddenInp = row.querySelector('.extractor-value-input');
      if (hiddenInp) hiddenInp.setAttribute('name', 'source_values[]');
    } else {
      jsonpath.classList.remove('d-none');
      predefined.classList.add('d-none');
      var jpInp2 = row.querySelector('.jsonpath-input');
      if (jpInp2) jpInp2.setAttribute('name', 'source_values[]');
      var hiddenInp2 = row.querySelector('.extractor-value-input');
      if (hiddenInp2) hiddenInp2.removeAttribute('name');
    }
  }

  function reindexSources() {
    var rows = document.querySelectorAll('#sources-list .source-row');
    rows.forEach(function (row, i) { row.setAttribute('data-source-index', i); });
  }

  // ---------------------------------------------------------------------------
  // Extractor picker (searchable dropdown)
  // ---------------------------------------------------------------------------

  function initExtractorPicker(row, selectedValue) {
    var searchInput  = row.querySelector('.extractor-search-input');
    var hiddenInput  = row.querySelector('.extractor-value-input');
    var dropdown     = row.querySelector('.extractor-dropdown');
    var noResults    = row.querySelector('.extractor-no-results');
    if (!searchInput || !hiddenInput || !dropdown) return;

    var allExtractors = pageState.extractors; // already fetched or will be

    function renderDropdown(filtered) {
      dropdown.innerHTML = '';
      if (filtered.length === 0) {
        dropdown.style.display = 'none';
        noResults.classList.remove('d-none');
        return;
      }
      noResults.classList.add('d-none');
      filtered.forEach(function (ext) {
        var li = document.createElement('li');
        li.className = 'list-group-item';
        li.setAttribute('role', 'option');
        li.setAttribute('data-value', ext.key);
        li.innerHTML =
          '<strong>' + escapeHtml(ext.label) + '</strong> ' +
          '<code class="small">' + escapeHtml(ext.key) + '</code>' +
          (ext.description ? '<br><span class="extractor-description">' + escapeHtml(ext.description) + '</span>' : '');

        li.addEventListener('click', function () {
          hiddenInput.value   = ext.key;
          searchInput.value   = ext.label + ' (' + ext.key + ')';
          dropdown.style.display = 'none';
          searchInput.setAttribute('aria-expanded', 'false');
          markDirty();
          triggerInFlightPreview();
        });

        li.addEventListener('keydown', function (e) {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            li.click();
          }
        });
        li.setAttribute('tabindex', '0');

        dropdown.appendChild(li);
      });
      dropdown.style.display = 'block';
      searchInput.setAttribute('aria-expanded', 'true');
    }

    searchInput.addEventListener('input', function () {
      var q = this.value.toLowerCase();
      var filtered = allExtractors.filter(function (e) {
        return e.key.toLowerCase().indexOf(q) !== -1 ||
               (e.label && e.label.toLowerCase().indexOf(q) !== -1) ||
               (e.description && e.description.toLowerCase().indexOf(q) !== -1);
      });
      renderDropdown(filtered);
    });

    searchInput.addEventListener('focus', function () {
      if (allExtractors.length && !hiddenInput.value) renderDropdown(allExtractors);
    });

    searchInput.addEventListener('blur', function () {
      // Delay hide so click on option registers first
      setTimeout(function () { dropdown.style.display = 'none'; }, 200);
    });

    // Keyboard navigation within dropdown
    searchInput.addEventListener('keydown', function (e) {
      var items = Array.from(dropdown.querySelectorAll('.list-group-item'));
      if (e.key === 'ArrowDown' && items.length) {
        e.preventDefault();
        items[0].focus();
      } else if (e.key === 'Escape') {
        dropdown.style.display = 'none';
      }
    });

    dropdown.addEventListener('keydown', function (e) {
      var items  = Array.from(dropdown.querySelectorAll('.list-group-item'));
      var active = document.activeElement;
      var idx    = items.indexOf(active);
      if (e.key === 'ArrowDown' && idx < items.length - 1) {
        e.preventDefault();
        items[idx + 1].focus();
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        if (idx > 0) items[idx - 1].focus();
        else         searchInput.focus();
      } else if (e.key === 'Escape') {
        dropdown.style.display = 'none';
        searchInput.focus();
      }
    });

    // Populate display if a value is already set
    if (selectedValue) {
      var match = allExtractors.find(function (e) { return e.key === selectedValue; });
      if (match) searchInput.value = match.label + ' (' + match.key + ')';
      else       searchInput.value = selectedValue;
    }
  }

  function fetchExtractors(recordType) {
    // See frontend/routes.rb for why this lives under /rules/ rather than the
    // bare /plugins/aeon_mapping/predefined_extractors path.
    var url = '/plugins/aeon_mapping/rules/predefined_extractors';
    if (recordType) url += '?record_type=' + encodeURIComponent(recordType);
    getJSON(url).then(function (data) {
      pageState.extractors = Array.isArray(data) ? data : [];
      // Re-init any picker already in the DOM
      document.querySelectorAll('.extractor-search-input').forEach(function (inp) {
        var row = inp.closest('.source-row');
        if (row) {
          var hiddenVal = row.querySelector('.extractor-value-input');
          initExtractorPicker(row, hiddenVal ? hiddenVal.value : '');
        }
      });
    }).catch(function (err) { console.error('AeonMapping: extractor fetch error', err); });
  }

  // ---------------------------------------------------------------------------
  // JSONPath validation + preview
  // ---------------------------------------------------------------------------

  function validateAndPreviewJsonPath(input) {
    var expr    = input.value.trim();
    var msgEl   = input.closest('.jsonpath-input-wrapper')
                       && input.closest('.jsonpath-input-wrapper').querySelector('.jsonpath-validation-msg');
    var resultEl = input.closest('.jsonpath-input-wrapper')
                        && input.closest('.jsonpath-input-wrapper').querySelector('.jsonpath-result-preview');

    if (!expr) {
      input.classList.remove('is-invalid', 'is-valid');
      if (msgEl)    msgEl.textContent = '';
      if (resultEl) resultEl.textContent = '';
      return;
    }

    // Client-side syntax check: very basic — just verify it starts with $ or is non-empty
    // Real validation happens server-side on save
    var valid = /^\$/.test(expr) || /^[a-zA-Z_$]/.test(expr);
    if (!valid) {
      input.classList.add('is-invalid');
      input.classList.remove('is-valid');
      if (msgEl) msgEl.textContent = getI18n('validation_jsonpath_invalid', 'Invalid JSONPath expression.');
      if (resultEl) resultEl.textContent = '';
      return;
    }

    input.classList.remove('is-invalid');
    input.classList.add('is-valid');
    if (msgEl) msgEl.textContent = '';

    // Live evaluation against current preview record
    if (pageState.previewJson && resultEl) {
      var result = evaluateJsonPathClient(expr, pageState.previewJson);
      if (result !== null && result !== undefined) {
        resultEl.textContent = '→ ' + JSON.stringify(result).substring(0, 120);
      } else {
        resultEl.textContent = '→ (no match)';
      }
    }
  }

  // Very simple client-side JSONPath evaluation using native property access
  // This is best-effort for UI feedback; the backend does authoritative evaluation
  function evaluateJsonPathClient(expr, json) {
    try {
      // Support simple $. paths
      if (!expr.startsWith('$')) return null;
      var parts = expr.replace(/^[$.]/, '').split(/[.\[\]'"]+/).filter(Boolean);
      var cur = json;
      for (var i = 0; i < parts.length; i++) {
        if (cur === null || cur === undefined) return null;
        cur = cur[parts[i]];
      }
      return cur;
    } catch (e) { return null; }
  }

  // ---------------------------------------------------------------------------
  // Template placeholder hints
  // ---------------------------------------------------------------------------

  function updateTemplateHints() {
    var hintsEl = document.getElementById('template-placeholder-hints');
    if (!hintsEl) return;

    // Select the placeholder inputs by their form name, NOT by an id prefix.
    // The id-prefix selector [id^="placeholder-"] also matched the
    // <small id="placeholder-help-N"> help elements, which have no `.value`
    // — calling .value.trim() on them threw and aborted populateModal(),
    // which is why the Edit button silently did nothing.
    var placeholders = Array.from(document.querySelectorAll('[name="placeholders[]"]'))
      .map(function (inp) { return (inp.value || '').trim(); })
      .filter(Boolean);

    hintsEl.innerHTML = '';
    placeholders.forEach(function (ph) {
      var badge = document.createElement('span');
      badge.className = 'badge badge-secondary';
      badge.textContent = '{' + ph + '}';
      badge.title = 'Click to insert into template';
      badge.addEventListener('click', function () {
        var tmplInp = document.getElementById('rule-template');
        if (!tmplInp) return;
        var pos = tmplInp.selectionStart;
        var val = tmplInp.value;
        tmplInp.value = val.substring(0, pos) + '{' + ph + '}' + val.substring(pos);
        markDirty();
      });
      hintsEl.appendChild(badge);
    });
  }

  // ---------------------------------------------------------------------------
  // Regex live test
  // ---------------------------------------------------------------------------

  function liveTestRegex() {
    var patInput = document.getElementById('rule-pattern');
    var outEl    = document.getElementById('regex-test-output');
    var valEl    = document.getElementById('pattern-validation');
    if (!patInput || !outEl) return;

    var pattern = patInput.value.trim();
    if (!pattern) {
      patInput.classList.remove('is-invalid', 'is-valid');
      outEl.textContent = '';
      return;
    }

    // Test if it compiles
    try {
      var re = new RegExp(pattern);
      patInput.classList.remove('is-invalid');
      patInput.classList.add('is-valid');
      if (valEl) valEl.textContent = '';

      // If we have a preview record, test against first source value
      var firstSrc = document.querySelector('.jsonpath-input, .extractor-value-input[name]');
      if (firstSrc && firstSrc.value && pageState.previewJson) {
        // Just show regex is valid for now
        outEl.textContent = 'Pattern is valid.';
      } else {
        outEl.textContent = 'Pattern is valid.';
      }
    } catch (e) {
      patInput.classList.add('is-invalid');
      patInput.classList.remove('is-valid');
      outEl.textContent = '';
      if (valEl) valEl.textContent = 'Invalid regex: ' + e.message;
    }
  }

  // ---------------------------------------------------------------------------
  // Form submission (AJAX)
  // ---------------------------------------------------------------------------

  // Turn a backend error payload into human-readable lines. Validation
  // failures arrive as {error: "Validation failed", errors: {field: [msgs]}};
  // other errors as {error: "..."}. ArchivesSpace's own error handlers can
  // also return {error: {field: [msgs]}} — an OBJECT — which naive string
  // conversion prints as "[object Object]", so every shape is unpacked to
  // one line per failing field.
  function formatRuleErrors(result) {
    var lines = [];

    function messageText(msgs) {
      if (Array.isArray(msgs)) return msgs.map(messageText).join('; ');
      if (msgs && typeof msgs === 'object') return JSON.stringify(msgs);
      return String(msgs);
    }

    function pushFieldLines(obj) {
      Object.keys(obj).forEach(function (field) {
        var label = field.replace(/_/g, ' ');
        label = label.charAt(0).toUpperCase() + label.slice(1);
        lines.push(label + ': ' + messageText(obj[field]));
      });
    }

    if (result.errors && typeof result.errors === 'object') {
      pushFieldLines(result.errors);
    }
    if (!lines.length) {
      if (typeof result.error === 'string' && result.error) {
        lines.push(result.error);
      } else if (result.error && typeof result.error === 'object') {
        pushFieldLines(result.error);
      }
    }
    if (!lines.length) {
      lines.push(getI18n('save_failed', 'Save failed.'));
    }
    return lines;
  }

  function renderRuleFormErrors(errEl, result) {
    if (!errEl) return;
    errEl.innerHTML = '';
    formatRuleErrors(result).forEach(function (line) {
      var div = document.createElement('div');
      div.textContent = line;
      errEl.appendChild(div);
    });
    errEl.classList.remove('d-none');
  }

  function submitRuleForm() {
    var form       = document.getElementById('rule-form');
    var ruleId     = document.getElementById('rule-form-rule-id').value;
    var repoId     = document.getElementById('rule-form-repo-id').value;
    var recordType = document.getElementById('rule-form-record-type').value;

    var body = buildRuleBodyFromForm(form, recordType);

    // Renaming a consumer default un-pairs any repository overrides of the
    // old name: they become repo-only rules, and the renamed default also
    // applies to those repositories. The rename stays allowed (admin-only,
    // rare, and the results are visible and deletable) but warrants an
    // explicit confirmation.
    if (ruleId && pageState.scope === 'global' &&
        pageState.modalOriginalField &&
        body.aeon_field_name !== pageState.modalOriginalField) {
      var renameMsg = getI18n('confirm_default_rename',
        'Renaming this application default un-pairs any repository overrides of "%{field}". ' +
        'Those overrides keep mapping the old field as separate repo-only rules, and the ' +
        'renamed default also applies to those repositories. Continue?')
        .replace('%{field}', pageState.modalOriginalField);
      if (!confirm(renameMsg)) return;
    }

    // Adding a rule whose Aeon field matches a consumer default silently
    // shadows that default for this repository — make the replacement
    // explicit before saving. (A duplicate within the same scope is
    // rejected by the backend with its own message.)
    if (!ruleId && pageState.scope !== 'global' && body.aeon_field_name) {
      var shadowsDefault = false;
      document.querySelectorAll('#rules-tbody .aeon-rule-row').forEach(function (row) {
        if (row.getAttribute('data-origin') === 'global' &&
            row.getAttribute('data-aeon-field') === body.aeon_field_name) {
          shadowsDefault = true;
        }
      });
      if (shadowsDefault) {
        var confirmMsg = getI18n('confirm_override_default',
          'An application default already maps this Aeon field. Your new rule will replace it for this repository. Continue?');
        if (!confirm(confirmMsg)) return;
      }
    }

    var url;
    if (pageState.scope === 'global') {
      url = ruleId
        ? ('/plugins/aeon_mapping/global_rules/' + ruleId)
        : '/plugins/aeon_mapping/global_rules';
    } else {
      url = ruleId
        ? ('/plugins/aeon_mapping/rules/' + ruleId + '?repo_id=' + repoId)
        : ('/plugins/aeon_mapping/rules?repo_id=' + repoId);
    }

    var errEl = document.getElementById('rule-form-errors');

    postJSON(url, body)
      .then(function (result) {
        if (result.error || result.errors) {
          renderRuleFormErrors(errEl, result);
          return;
        }
        pageState.rulesDirty = false;
        hideModal();
        // Park the confirmation across the reload — the saved row can land
        // below the fold (a renamed override sorts to the bottom), so the
        // table itself is not visible feedback. init shows this as a toast.
        try {
          sessionStorage.setItem('aeonMappingSavedRule', JSON.stringify({
            action: ruleId ? 'updated' : 'created',
            field:  (result && result.aeon_field_name) || body.aeon_field_name || ''
          }));
        } catch (e) { /* sessionStorage unavailable — skip the toast */ }
        window.location.reload();
      })
      .catch(function (err) {
        renderRuleFormErrors(errEl, { error: 'Error: ' + err.message });
      });
  }

  function buildRuleBodyFromForm(form, recordType) {
    var aeonFieldName     = document.getElementById('rule-aeon-field-name').value.trim();
    var transformationType = document.getElementById('rule-transformation-type').value;
    var enabled           = document.getElementById('rule-enabled').checked;

    var opts = {};
    var tt = transformationType;
    if (tt === 'concat') {
      opts.delimiter = document.getElementById('rule-delimiter').value;
    } else if (tt === 'template') {
      opts.template = document.getElementById('rule-template').value;
    } else if (tt === 'extract') {
      opts.pattern = document.getElementById('rule-pattern').value;
    }

    // Max length applies to every transformation type
    var maxLenInp = document.getElementById('rule-max-length');
    if (maxLenInp && maxLenInp.value.trim() !== '') {
      var maxLen = parseInt(maxLenInp.value, 10);
      if (!isNaN(maxLen) && maxLen > 0) opts.max_length = maxLen;
    }

    // Collect sources
    var sources = [];
    var rows = document.querySelectorAll('#sources-list .source-row');
    rows.forEach(function (row) {
      var typeRadio = row.querySelector('input[name="source_types[]"]:checked');
      var stype = typeRadio ? typeRadio.value : 'predefined';
      var sval  = '';
      if (stype === 'predefined') {
        var hInp = row.querySelector('.extractor-value-input[name="source_values[]"]');
        sval = hInp ? hInp.value : '';
      } else {
        var jpInp = row.querySelector('.jsonpath-input[name="source_values[]"]');
        sval = jpInp ? jpInp.value : '';
      }
      var phInp = row.querySelector('[name="placeholders[]"]');
      sources.push({
        source_type:  stype,
        source_value: sval,
        placeholder:  phInp && phInp.value ? phInp.value : null,
        sort_order:   sources.length
      });
    });

    return {
      consumer:               pageState.consumer,
      record_type:            recordType,
      aeon_field_name:        aeonFieldName,
      transformation_type:    transformationType,
      transformation_options: opts,
      enabled:                enabled,
      sources:                sources
    };
  }

  // ---------------------------------------------------------------------------
  // Preview panel
  // ---------------------------------------------------------------------------

  function initPreviewPanel() {
    var loadBtn = document.getElementById('preview-load-btn');
    if (loadBtn) {
      loadBtn.addEventListener('click', function () {
        var uri = document.getElementById('preview-record-uri').value.trim();
        if (uri) loadPreview(uri);
      });
    }

    var uriInput = document.getElementById('preview-record-uri');
    if (uriInput) {
      uriInput.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') {
          e.preventDefault();
          var uri = this.value.trim();
          if (uri) loadPreview(uri);
        }
      });

      // Restore last-used URI for this record_type from localStorage and
      // auto-load so the user lands back exactly where they left off.
      var savedUri = readSavedRecordUri(pageState.recordType);
      if (savedUri) {
        uriInput.value = savedUri;
        // Defer so the rest of init runs first
        setTimeout(function () { loadPreview(savedUri); }, 100);
      }
    }

    // Browse button — opens AS's record search modal scoped to current
    // record_type / repo so the user can pick a record visually.
    var browseBtn = document.getElementById('preview-browse-btn');
    if (browseBtn) {
      browseBtn.addEventListener('click', function () { openRecordBrowser(); });
    }

    // Tab switching (Trace / Raw JSON)
    initPreviewTabs();
  }

  function initPreviewTabs() {
    var tabs = document.querySelectorAll('#preview-panel .nav-tabs button[role="tab"]');
    if (!tabs.length) return;
    tabs.forEach(function (tab) {
      tab.addEventListener('click', function () {
        var target = this.getAttribute('data-target');
        // Update tab states
        tabs.forEach(function (t) {
          var isActive = t === tab;
          t.classList.toggle('active', isActive);
          t.setAttribute('aria-selected', isActive ? 'true' : 'false');
        });
        // Update panel visibility
        document.querySelectorAll('#preview-panel .tab-pane').forEach(function (panel) {
          var isActive = panel.id === 'preview-tabpanel-' + target;
          panel.classList.toggle('active', isActive);
          if (isActive) {
            panel.removeAttribute('hidden');
          } else {
            panel.setAttribute('hidden', '');
          }
        });
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Persisted record URI (localStorage)
  // ---------------------------------------------------------------------------

  function recordUriStorageKey(recordType) {
    return 'aeon_mapping.last_record_uri.' + (recordType || pageState.recordType || 'unknown');
  }

  function readSavedRecordUri(recordType) {
    try {
      return localStorage.getItem(recordUriStorageKey(recordType));
    } catch (e) { return null; }
  }

  function saveRecordUri(recordType, uri) {
    try {
      if (uri) localStorage.setItem(recordUriStorageKey(recordType), uri);
    } catch (e) { /* localStorage may be unavailable */ }
  }

  // ---------------------------------------------------------------------------
  // Record browser modal — searches AS for a record and lets the user pick one
  // ---------------------------------------------------------------------------

  function openRecordBrowser() {
    var modal = document.getElementById('record-browser-modal');
    if (!modal) {
      modal = buildRecordBrowserModal();
      document.body.appendChild(modal);
    }
    if (window.jQuery) {
      window.jQuery(modal).modal('show');
    } else {
      modal.classList.add('show');
      modal.style.display = 'block';
    }
    var input = modal.querySelector('#record-browser-search');
    if (input) {
      setTimeout(function () { input.focus(); }, 100);
    }
  }

  function buildRecordBrowserModal() {
    var t = function (k, f) { return getI18n('preview_' + k, f); };
    var html =
      '<div class="modal" tabindex="-1" role="dialog" id="record-browser-modal" aria-labelledby="record-browser-title" aria-hidden="true">' +
        '<div class="modal-dialog modal-lg" role="document">' +
          '<div class="modal-content">' +
            '<div class="modal-header">' +
              '<h5 class="modal-title" id="record-browser-title">' + t('browse_modal_title', 'Pick a record') + '</h5>' +
              '<button type="button" class="close" data-dismiss="modal" aria-label="Close"><span aria-hidden="true">&times;</span></button>' +
            '</div>' +
            '<div class="modal-body">' +
              '<p class="small text-muted">' + t('browse_modal_help', 'Search ArchivesSpace for a record, then click Use this record to load it into the preview.') + '</p>' +
              '<div class="form-group">' +
                '<input type="text" class="form-control" id="record-browser-search" placeholder="' + t('browse_modal_search_placeholder', 'Search by title, identifier, or component ID') + '" autocomplete="off">' +
              '</div>' +
              '<div id="record-browser-status" class="small text-muted mb-2"></div>' +
              '<ul class="list-group" id="record-browser-results"></ul>' +
            '</div>' +
            '<div class="modal-footer">' +
              '<button type="button" class="btn btn-secondary" data-dismiss="modal">' + t('browse_cancel', 'Cancel') + '</button>' +
            '</div>' +
          '</div>' +
        '</div>' +
      '</div>';
    var wrap = document.createElement('div');
    wrap.innerHTML = html;
    var modal = wrap.firstChild;

    // Debounced search
    var searchTimer = null;
    modal.querySelector('#record-browser-search').addEventListener('input', function () {
      var q = this.value.trim();
      clearTimeout(searchTimer);
      if (q.length < 2) {
        modal.querySelector('#record-browser-results').innerHTML = '';
        modal.querySelector('#record-browser-status').textContent = '';
        return;
      }
      modal.querySelector('#record-browser-status').textContent = t('browse_modal_searching', 'Searching...');
      searchTimer = setTimeout(function () { runRecordBrowserSearch(q, modal); }, 300);
    });

    return modal;
  }

  function runRecordBrowserSearch(query, modal) {
    var recordType = pageState.recordType;
    if (recordType === 'instance') recordType = 'archival_object';  // instances live under AOs
    // AS's frontend search controller is at /search (not /repositories/:id/search)
    // and returns results under data.search_data.results.
    var url = '/search'
            + '?q=' + encodeURIComponent(query)
            + '&type[]=' + encodeURIComponent(recordType)
            + '&page=1';
    getJSON(url).then(function (data) {
      var results = (data && data.search_data && data.search_data.results) || [];
      var resultsEl = modal.querySelector('#record-browser-results');
      var statusEl  = modal.querySelector('#record-browser-status');
      resultsEl.innerHTML = '';
      if (!results.length) {
        statusEl.textContent = getI18n('preview_browse_modal_no_results', 'No records found. Try a different search.');
        return;
      }
      statusEl.textContent = '';
      results.forEach(function (r) {
        var li = document.createElement('li');
        li.className = 'list-group-item d-flex justify-content-between align-items-center';
        var info = document.createElement('div');
        var title = document.createElement('div');
        title.className = 'font-weight-bold';
        title.textContent = r.title || r.display_string || r.uri;
        var sub = document.createElement('small');
        sub.className = 'text-muted';
        var label = r.identifier || r.component_id || '';
        sub.textContent = (label ? label + ' — ' : '') + r.uri;
        info.appendChild(title);
        info.appendChild(sub);
        var btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'btn btn-sm btn-primary';
        btn.textContent = getI18n('preview_browse_use_record', 'Use this record');
        btn.addEventListener('click', function () {
          var uriInput = document.getElementById('preview-record-uri');
          uriInput.value = r.uri;
          if (window.jQuery) {
            window.jQuery(modal).modal('hide');
          } else {
            modal.classList.remove('show');
            modal.style.display = 'none';
          }
          loadPreview(r.uri);
        });
        li.appendChild(info);
        li.appendChild(btn);
        resultsEl.appendChild(li);
      });
    }).catch(function (err) {
      modal.querySelector('#record-browser-status').textContent = 'Error: ' + err.message;
    });
  }

  function loadPreview(recordUri) {
    var panel      = document.getElementById('preview-panel');
    var repoId     = panel ? panel.getAttribute('data-repo-id') : pageState.repoId;
    var recordType = panel ? panel.getAttribute('data-record-type') : pageState.recordType;
    var panelScope = panel ? (panel.getAttribute('data-scope') || 'repo') : pageState.scope;

    // Persist the URI so the next visit to this record_type remembers it
    saveRecordUri(recordType, recordUri);

    clearPreviewError();
    showPreviewLoading(true);

    var previewUrl = panelScope === 'global'
      ? '/plugins/aeon_mapping/global_preview'
      : ('/plugins/aeon_mapping/preview?repo_id=' + repoId);

    postJSON(
      previewUrl,
      { consumer: pageState.consumer, record_type: recordType, record_uri: recordUri }
    ).then(function (data) {
      showPreviewLoading(false);
      if (data.error) {
        showPreviewError(data.error);
        return;
      }
      pageState.previewJson = data.raw_json;
      pageState.previewRules = data.rules || [];
      pageState.previewExtracted = data.extracted_values || {};
      pageState.previewMapped = data.mapped_output || {};
      renderPreview(data);
    }).catch(function (err) {
      showPreviewLoading(false);
      showPreviewError(err.message);
    });
  }

  function triggerInFlightPreview() {
    // Collect in-flight rules from the open modal (if open)
    var modal = document.getElementById('rule-form-modal');
    if (!modal || !modal.classList.contains('show')) return;

    var form       = document.getElementById('rule-form');
    var recordType = document.getElementById('rule-form-record-type').value;
    var body       = buildRuleBodyFromForm(form, recordType);

    // Only meaningful if we have a preview record loaded
    if (!pageState.previewJson) return;

    var recordUri = document.getElementById('preview-record-uri');
    if (!recordUri || !recordUri.value) return;

    var panel      = document.getElementById('preview-panel');
    var repoId     = panel ? panel.getAttribute('data-repo-id') : pageState.repoId;
    var panelScope = panel ? (panel.getAttribute('data-scope') || 'repo') : pageState.scope;

    var inFlightPreviewUrl = panelScope === 'global'
      ? '/plugins/aeon_mapping/global_preview'
      : ('/plugins/aeon_mapping/preview?repo_id=' + repoId);

    postJSON(
      inFlightPreviewUrl,
      {
        consumer:       pageState.consumer,
        record_type:    recordType,
        record_uri:     recordUri.value.trim(),
        in_flight_rules: [body]
      }
    ).then(function (data) {
      if (data.error) return;
      // In-flight preview: only the in-flight rule was evaluated, so the
      // trace shows just that rule. We still want to surface the result so
      // users see the effect of their edits immediately.
      renderTraceTable(
        data.rules || [],
        data.extracted_values || {},
        data.mapped_output || {}
      );
    }).catch(function () {});
  }

  function showPreviewLoading(loading) {
    var loadEl  = document.getElementById('preview-loading');
    var emptyEl = document.getElementById('preview-empty-msg');
    var errEl   = document.getElementById('preview-error');
    if (loading) {
      if (loadEl)  loadEl.classList.remove('d-none');
      if (emptyEl) emptyEl.classList.add('d-none');
      if (errEl)   errEl.classList.add('d-none');
    } else {
      if (loadEl) loadEl.classList.add('d-none');
    }
  }

  function clearPreviewError() {
    var errEl = document.getElementById('preview-error');
    if (errEl) {
      errEl.textContent = '';
      errEl.classList.add('d-none');
    }
  }

  function showPreviewError(msg) {
    // Use a dedicated alert element so the empty-state message is NEVER
    // overwritten with stale error text.
    var errEl = document.getElementById('preview-error');
    if (errEl) {
      errEl.textContent = 'Error: ' + msg;
      errEl.classList.remove('d-none');
    }
    var emptyEl = document.getElementById('preview-empty-msg');
    if (emptyEl) emptyEl.classList.add('d-none');
  }

  function renderPreview(data) {
    // Truncation notice
    var trunc = document.getElementById('preview-truncated-notice');
    if (trunc) {
      data.truncated ? trunc.classList.remove('d-none') : trunc.classList.add('d-none');
    }

    // Hide empty/error, clear error text
    var emptyEl = document.getElementById('preview-empty-msg');
    if (emptyEl) emptyEl.classList.add('d-none');
    clearPreviewError();

    // Show the tabbed body
    var tabsWrap = document.getElementById('preview-tabs-wrapper');
    if (tabsWrap) tabsWrap.classList.remove('d-none');

    // Render the trace table (combined sources/extracted/final)
    renderTraceTable(
      data.rules || [],
      data.extracted_values || {},
      data.mapped_output || {}
    );

    // Render unused-extractors expander
    renderUnusedExtractors(data.extracted_values || {}, data.rules || []);

    // Raw JSON tree
    var treeEl = document.getElementById('raw-json-tree');
    if (treeEl) renderJsonTree(data.raw_json, treeEl);

    // ARIA live region
    var liveEl = document.getElementById('preview-live-region');
    if (liveEl) liveEl.textContent = getI18n('preview_updated', 'Preview updated.');
  }

  // ---------------------------------------------------------------------------
  // Combined trace table: per-rule view of Sources → Extracted → Final Output
  // ---------------------------------------------------------------------------

  function renderTraceTable(rules, extractedValues, mappedOutput) {
    var tbody = document.getElementById('trace-table-body');
    if (!tbody) return;
    tbody.innerHTML = '';

    var systemFields = ['SystemID', 'ReturnLinkURL', 'ReturnLinkSystemName', 'Site'];

    // The server sends rules in engine order (defaults block first, with an
    // override sitting in its default's slot even when its stored number
    // differs, then repository-only rules). Render as received — a
    // client-side re-sort by raw sort_order would break that arrangement.

    // Track which Aeon field names are addressed by rules so we can append
    // system-injected fields (SystemID, ReturnLinkURL, etc.) afterward.
    var seen = {};

    rules.forEach(function (rule) {
      seen[rule.aeon_field_name] = true;
      var tr  = document.createElement('tr');
      tr.className = 'trace-row' + (rule.enabled === false ? ' trace-row-disabled' : '');

      // Cell 1: Aeon field name (+ disabled indicator)
      var tdField = document.createElement('td');
      tdField.className = 'trace-aeon-field font-weight-bold';
      tdField.textContent = rule.aeon_field_name;
      if (rule.enabled === false) {
        var dim = document.createElement('span');
        dim.className = 'badge badge-secondary ml-1';
        dim.textContent = 'disabled';
        tdField.appendChild(dim);
      }
      tr.appendChild(tdField);

      // Cell 2: Sources with their extracted values
      var tdSources = document.createElement('td');
      tdSources.className = 'trace-sources';
      (rule.sources || []).forEach(function (src) {
        var item = document.createElement('div');
        item.className = 'trace-source-item';

        var label = document.createElement('span');
        label.className = 'badge badge-' + (src.source_type === 'jsonpath' ? 'info' : 'primary') + ' mr-1 trace-source-label';
        label.textContent = src.source_type === 'jsonpath' ? 'JSONPath' : 'Predefined';
        item.appendChild(label);

        var key = document.createElement('code');
        key.className = 'trace-source-key';
        key.textContent = src.source_value;
        item.appendChild(key);

        var arrow = document.createElement('span');
        arrow.className = 'trace-source-arrow';
        arrow.textContent = ' → ';
        item.appendChild(arrow);

        var val = document.createElement('span');
        val.className = 'trace-source-value';
        var extractedVal = null;
        if (src.source_type === 'predefined') {
          extractedVal = extractedValues[src.source_value];
        }
        // For JSONPath sources we don't have a pre-extracted value to show
        // (the server only pre-extracts predefined extractors). The final
        // output still reflects the actual JSONPath result via mappedOutput.
        if (extractedVal === null || extractedVal === undefined || extractedVal === '') {
          val.className += ' trace-source-empty';
          val.textContent = src.source_type === 'jsonpath'
            ? '(see final output)'
            : getI18n('preview_empty_value', '(empty)');
        } else {
          val.textContent = formatTraceValue(extractedVal);
        }
        item.appendChild(val);

        tdSources.appendChild(item);
      });
      tr.appendChild(tdSources);

      // Cell 3: Final mapped output
      var tdFinal = document.createElement('td');
      tdFinal.className = 'trace-final';
      var finalVal = mappedOutput[rule.aeon_field_name];
      if (finalVal === undefined || finalVal === null || finalVal === '') {
        tdFinal.className += ' trace-final-empty';
        var emptyMsg = document.createElement('em');
        emptyMsg.className = 'text-muted';
        emptyMsg.textContent = getI18n('preview_rule_excluded_empty', 'Rule excluded (empty result)');
        tdFinal.appendChild(emptyMsg);
      } else {
        tdFinal.textContent = formatTraceValue(finalVal);
      }
      tr.appendChild(tdFinal);

      tbody.appendChild(tr);
    });

    // Append system-injected fields (SystemID etc.) as a separate group
    systemFields.forEach(function (sf) {
      if (seen[sf]) return;
      if (mappedOutput[sf] === undefined) return;
      var tr = document.createElement('tr');
      tr.className = 'trace-row trace-row-system';

      var tdField = document.createElement('td');
      tdField.className = 'trace-aeon-field font-weight-bold';
      tdField.textContent = sf;
      var badge = document.createElement('span');
      badge.className = 'badge badge-light ml-1';
      badge.textContent = 'system';
      tdField.appendChild(badge);
      tr.appendChild(tdField);

      var tdSources = document.createElement('td');
      tdSources.className = 'trace-sources text-muted';
      tdSources.innerHTML = '<small><em>Injected by plugin (not configurable)</em></small>';
      tr.appendChild(tdSources);

      var tdFinal = document.createElement('td');
      tdFinal.className = 'trace-final';
      tdFinal.textContent = formatTraceValue(mappedOutput[sf]);
      tr.appendChild(tdFinal);

      tbody.appendChild(tr);
    });
  }

  function formatTraceValue(v) {
    if (v === null || v === undefined) return '';
    if (Array.isArray(v)) return v.map(formatTraceValue).join(', ');
    if (typeof v === 'object') {
      try { return JSON.stringify(v); } catch (e) { return String(v); }
    }
    return String(v);
  }

  function renderUnusedExtractors(extractedValues, rules) {
    var list = document.getElementById('unused-extractors-list');
    if (!list) return;
    list.innerHTML = '';

    // Build a set of extractor keys consumed by rules
    var used = {};
    (rules || []).forEach(function (r) {
      (r.sources || []).forEach(function (s) {
        if (s.source_type === 'predefined') used[s.source_value] = true;
      });
    });

    var keys = Object.keys(extractedValues || {});
    var any = false;
    keys.forEach(function (key) {
      if (used[key]) return;
      any = true;
      var dt = document.createElement('dt');
      dt.textContent = key;
      var dd = document.createElement('dd');
      dd.textContent = formatTraceValue(extractedValues[key]);
      list.appendChild(dt);
      list.appendChild(dd);
    });

    if (!any) {
      var dd = document.createElement('dd');
      dd.className = 'text-muted';
      dd.innerHTML = '<small><em>All extractors with values are used by rules.</em></small>';
      list.appendChild(dd);
    }
  }

  function renderMappedOutput(mapped) {
    var listEl = document.getElementById('mapped-output-list');
    var col    = document.getElementById('preview-mapped-output-col');
    if (!listEl || !col) return;
    col.classList.remove('d-none');

    listEl.innerHTML = '';
    var keys = Object.keys(mapped);
    if (keys.length === 0) {
      listEl.innerHTML = '<dd class="text-muted">' + getI18n('empty_output', '(no values mapped)') + '</dd>';
      return;
    }
    keys.forEach(function (key) {
      var dt = document.createElement('dt');
      dt.textContent = key;
      var dd = document.createElement('dd');
      dd.textContent = String(mapped[key]);
      listEl.appendChild(dt);
      listEl.appendChild(dd);
    });
  }

  // ---------------------------------------------------------------------------
  // JSON tree renderer with click-to-copy JSONPath
  // ---------------------------------------------------------------------------

  function renderJsonTree(json, container) {
    container.innerHTML = '';
    var tree = buildJsonNode(json, '$', 0);
    container.appendChild(tree);
  }

  function buildJsonNode(value, path, depth) {
    var span = document.createElement('span');

    if (value === null) {
      span.className = 'json-null';
      span.textContent = 'null';
      return makeClickable(span, path);
    }

    if (typeof value === 'boolean') {
      span.className = 'json-boolean';
      span.textContent = String(value);
      return makeClickable(span, path);
    }

    if (typeof value === 'number') {
      span.className = 'json-number';
      span.textContent = String(value);
      return makeClickable(span, path);
    }

    if (typeof value === 'string') {
      span.className = 'json-string';
      span.textContent = '"' + escapeHtml(value.substring(0, 200)) + (value.length > 200 ? '…' : '') + '"';
      return makeClickable(span, path);
    }

    if (Array.isArray(value)) {
      var wrap = document.createElement('details');
      wrap.open = depth < 2;
      var summary = document.createElement('summary');
      summary.className = 'json-key';
      summary.textContent = '[' + value.length + ']';
      wrap.appendChild(summary);
      value.forEach(function (item, i) {
        var line = document.createElement('div');
        line.style.paddingLeft = '1rem';
        var keySpan = document.createElement('span');
        keySpan.className = 'json-key';
        keySpan.textContent = i + ': ';
        line.appendChild(keySpan);
        line.appendChild(buildJsonNode(item, path + '[' + i + ']', depth + 1));
        wrap.appendChild(line);
      });
      span.appendChild(wrap);
      return span;
    }

    if (typeof value === 'object') {
      var objWrap = document.createElement('details');
      objWrap.open = depth < 2;
      var objSummary = document.createElement('summary');
      objSummary.className = 'json-key';
      objSummary.textContent = '{' + Object.keys(value).length + ' keys}';
      objWrap.appendChild(objSummary);
      Object.keys(value).forEach(function (key) {
        var line = document.createElement('div');
        line.style.paddingLeft = '1rem';
        var keySpan2 = document.createElement('span');
        keySpan2.className = 'json-key';
        keySpan2.textContent = '"' + key + '": ';
        line.appendChild(keySpan2);
        var childPath = /^[a-zA-Z_$][a-zA-Z0-9_$]*$/.test(key)
          ? path + '.' + key
          : path + '["' + key + '"]';
        line.appendChild(buildJsonNode(value[key], childPath, depth + 1));
        objWrap.appendChild(line);
      });
      span.appendChild(objWrap);
      return span;
    }

    span.textContent = String(value);
    return span;
  }

  function makeClickable(span, path) {
    span.classList.add('json-value-clickable');
    span.setAttribute('tabindex', '0');
    span.setAttribute('role', 'button');
    span.setAttribute('aria-label', getI18n('copy_path', 'Copy JSONPath') + ': ' + path);
    span.title = path;

    function doCopy() {
      copyTextRobust(path)
        .then(function (method) {
          showToast(getI18n('jsonpath_copied', 'JSONPath copied to clipboard.'));
        })
        .catch(function () {
          // Both clipboard methods failed — surface the path to the user so
          // they can copy it manually.
          showToast(getI18n('preview_jsonpath_copy_failed_html', 'Could not copy automatically. Path: ') + path);
        });
    }

    span.addEventListener('click', doCopy);
    span.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); doCopy(); }
    });
    return span;
  }

  // ---------------------------------------------------------------------------
  // Unsaved changes warning on page navigation
  // ---------------------------------------------------------------------------

  window.addEventListener('beforeunload', function (e) {
    if (pageState.rulesDirty) {
      e.preventDefault();
      e.returnValue = '';
    }
  });

  // ---------------------------------------------------------------------------
  // Utility: escape HTML
  // ---------------------------------------------------------------------------

  function escapeHtml(str) {
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  // ---------------------------------------------------------------------------
  // Utility: get i18n strings from data attributes on body or hard fallbacks
  // ---------------------------------------------------------------------------

  // Page-script strings live in en.yml under plugins.aeon_mapping.js and
  // reach here as data attributes on the page container (rendered by
  // aeon_mapping_js_i18n_attributes). The fallback covers a missing key.
  function getI18n(key, fallback) {
    var page = document.getElementById('aeon-mapping-page');
    if (!page) return fallback;
    var val = page.getAttribute('data-i18n-aeon-' + key.replace(/_/g, '-'));
    return val || fallback;
  }

})();
