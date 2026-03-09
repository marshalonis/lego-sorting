/* ── Auth ── */
let _cognitoConfig = null;
let _challengeSession = null;

async function initAuth() {
  const res = await fetch('/api/config');
  _cognitoConfig = await res.json();

  if (localStorage.getItem('access_token')) {
    const ok = await _validateToken();
    if (ok) { await showAppOrPicker(); return; }
  }
  document.getElementById('login-overlay').hidden = false;
}

async function _validateToken() {
  try {
    const res = await apiFetch('/api/catalog/status');
    if (res.ok) return true;
  } catch {}
  return tryRefreshToken();
}

async function tryRefreshToken() {
  const rt = localStorage.getItem('refresh_token');
  if (!rt || !_cognitoConfig) return false;
  try {
    const data = await _cognitoCall('InitiateAuth', {
      AuthFlow: 'REFRESH_TOKEN_AUTH',
      AuthParameters: { REFRESH_TOKEN: rt },
      ClientId: _cognitoConfig.client_id,
    });
    if (data.AuthenticationResult?.AccessToken) {
      localStorage.setItem('access_token', data.AuthenticationResult.AccessToken);
      return true;
    }
  } catch {}
  return false;
}

async function showAppOrPicker() {
  document.getElementById('login-overlay').hidden = true;
  const savedId = localStorage.getItem('project_id');
  if (savedId) {
    // Validate the stored project (user may have been removed)
    try {
      const res = await apiFetch(`/api/projects/${savedId}`);
      if (res.ok) {
        const proj = await res.json();
        selectProject(proj, false);
        return;
      }
    } catch {}
    localStorage.removeItem('project_id');
  }
  showProjectPicker();
}

async function _cognitoCall(target, body) {
  const res = await fetch(
    `https://cognito-idp.${_cognitoConfig.region}.amazonaws.com/`,
    {
      method: 'POST',
      headers: {
        'X-Amz-Target': `AWSCognitoIdentityProviderService.${target}`,
        'Content-Type': 'application/x-amz-json-1.1',
      },
      body: JSON.stringify(body),
    }
  );
  return res.json();
}

async function submitLogin() {
  const email = document.getElementById('login-email').value.trim();
  const password = document.getElementById('login-password').value;
  const errorEl = document.getElementById('login-error');
  errorEl.hidden = true;

  try {
    const data = await _cognitoCall('InitiateAuth', {
      AuthFlow: 'USER_PASSWORD_AUTH',
      AuthParameters: { USERNAME: email, PASSWORD: password },
      ClientId: _cognitoConfig.client_id,
    });

    if (data.ChallengeName === 'NEW_PASSWORD_REQUIRED') {
      _challengeSession = { session: data.Session, email };
      document.getElementById('login-form').hidden = true;
      document.getElementById('new-password-form').hidden = false;
      return;
    }

    if (data.AuthenticationResult) {
      _storeTokens(data.AuthenticationResult);
      await showAppOrPicker();
      return;
    }

    errorEl.textContent = data.message || 'Login failed';
    errorEl.hidden = false;
  } catch (err) {
    errorEl.textContent = 'Login error: ' + err.message;
    errorEl.hidden = false;
  }
}

async function submitNewPassword() {
  const newPw = document.getElementById('new-password').value;
  const confirm = document.getElementById('new-password-confirm').value;
  const errorEl = document.getElementById('new-password-error');
  errorEl.hidden = true;

  if (newPw !== confirm) {
    errorEl.textContent = 'Passwords do not match';
    errorEl.hidden = false;
    return;
  }

  try {
    const data = await _cognitoCall('RespondToAuthChallenge', {
      ChallengeName: 'NEW_PASSWORD_REQUIRED',
      ClientId: _cognitoConfig.client_id,
      Session: _challengeSession.session,
      ChallengeResponses: {
        USERNAME: _challengeSession.email,
        NEW_PASSWORD: newPw,
      },
    });

    if (data.AuthenticationResult) {
      _storeTokens(data.AuthenticationResult);
      await showAppOrPicker();
      return;
    }

    errorEl.textContent = data.message || 'Failed to set new password';
    errorEl.hidden = false;
  } catch (err) {
    errorEl.textContent = 'Error: ' + err.message;
    errorEl.hidden = false;
  }
}

function _storeTokens(result) {
  localStorage.setItem('access_token', result.AccessToken);
  if (result.RefreshToken) localStorage.setItem('refresh_token', result.RefreshToken);
}

function logout() {
  localStorage.removeItem('access_token');
  localStorage.removeItem('refresh_token');
  localStorage.removeItem('project_id');
  currentProjectId = null;
  currentProjectName = null;
  document.getElementById('project-overlay').hidden = true;
  document.getElementById('app-shell').hidden = true;
  document.getElementById('login-overlay').hidden = false;
}

async function apiFetch(url, options = {}) {
  const token = localStorage.getItem('access_token');
  const headers = { ...(options.headers || {}), Authorization: `Bearer ${token}` };
  let res = await fetch(url, { ...options, headers });

  if (res.status === 401) {
    if (await tryRefreshToken()) {
      headers.Authorization = `Bearer ${localStorage.getItem('access_token')}`;
      res = await fetch(url, { ...options, headers });
    } else {
      localStorage.removeItem('access_token');
      localStorage.removeItem('refresh_token');
      document.getElementById('login-overlay').hidden = false;
      throw new Error('Session expired. Please log in again.');
    }
  }
  return res;
}

/* ── Projects ── */
let currentProjectId = null;
let currentProjectName = null;

function apiProject(path, options = {}) {
  return apiFetch(`/api/projects/${currentProjectId}${path}`, options);
}

async function showProjectPicker() {
  document.getElementById('app-shell').hidden = true;
  const overlay = document.getElementById('project-overlay');
  overlay.hidden = false;

  const listEl = document.getElementById('project-list');
  listEl.innerHTML = '<p style="color:var(--text-muted);font-size:14px;">Loading…</p>';
  document.getElementById('create-project-form').hidden = true;
  document.getElementById('new-project-name').value = '';

  try {
    const res = await apiFetch('/api/projects');
    const projects = await res.json();
    if (projects.length === 0) {
      listEl.innerHTML = '<p style="color:var(--text-muted);font-size:14px;margin-bottom:12px;">No projects yet. Create one to get started.</p>';
    } else {
      listEl.innerHTML = projects.map(p => `
        <button class="btn btn-secondary w-full" style="margin-bottom:8px;text-align:left;"
                onclick="selectProject(${JSON.stringify(p).replace(/"/g, '&quot;')}, true)">
          <strong>${esc(p.name)}</strong>
        </button>
      `).join('');
    }
  } catch (err) {
    listEl.innerHTML = `<p style="color:var(--error,#f66);font-size:14px;">${esc(err.message)}</p>`;
  }
}

function showCreateProject() {
  document.getElementById('create-project-form').hidden = false;
  document.getElementById('new-project-name').focus();
}

async function createProject() {
  const name = document.getElementById('new-project-name').value.trim();
  if (!name) return;
  try {
    const res = await apiFetch('/api/projects', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name }),
    });
    if (!res.ok) throw new Error(await res.text());
    const proj = await res.json();
    selectProject(proj, true);
  } catch (err) {
    alert('Error creating project: ' + err.message);
  }
}

function selectProject(proj, saveToStorage) {
  currentProjectId = proj.project_id;
  currentProjectName = proj.name;
  if (saveToStorage) localStorage.setItem('project_id', proj.project_id);
  document.getElementById('project-overlay').hidden = true;
  document.getElementById('app-shell').hidden = false;
  document.getElementById('current-project-name').textContent = proj.name;
  initCatalogSearch();
}

/* ── State ── */
let currentAi = null;
let currentPart = null;
let allDrawers = [];
let editingPartNum = null;

/* ── Navigation ── */
document.querySelectorAll('.nav-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    const viewId = 'view-' + btn.dataset.view;
    document.querySelectorAll('.view').forEach(v => v.hidden = true);
    document.getElementById(viewId).hidden = false;
    document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    if (btn.dataset.view === 'identify') initCatalogSearch();
    if (btn.dataset.view === 'browse') loadBrowse();
    if (btn.dataset.view === 'drawers') loadDrawers();
    if (btn.dataset.view === 'data') loadDataStats();
  });
});

initAuth();

/* ── View: Identify ── */
document.getElementById('file-input').addEventListener('change', async (e) => {
  const file = e.target.files[0];
  if (!file) return;

  const reader = new FileReader();
  reader.onload = ev => {
    document.getElementById('preview-img').src = ev.target.result;
  };
  reader.readAsDataURL(file);
  document.getElementById('upload-prompt').hidden = true;
  document.getElementById('upload-preview').hidden = false;

  await identifyImage(file);
  e.target.value = '';
});

async function identifyImage(file) {
  document.getElementById('identify-result').hidden = true;
  document.getElementById('identify-loading').hidden = false;

  try {
    const uploadRes = await apiFetch('/api/images/upload', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content_type: file.type || 'image/jpeg' }),
    });
    if (!uploadRes.ok) throw new Error('Failed to get upload URL');
    const { upload_url, s3_key } = await uploadRes.json();

    const s3Res = await fetch(upload_url, {
      method: 'PUT',
      headers: { 'Content-Type': file.type || 'image/jpeg' },
      body: file,
    });
    if (!s3Res.ok) throw new Error('Failed to upload image to S3');

    const res = await apiProject('/identify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ s3_key }),
    });
    if (!res.ok) throw new Error(await res.text());
    const data = await res.json();
    showIdentifyResult(data);
  } catch (err) {
    alert('Error identifying part: ' + err.message);
  } finally {
    document.getElementById('identify-loading').hidden = true;
  }
}

function showIdentifyResult(data) {
  currentAi = data.ai;
  currentPart = data.existing;

  const ai = data.ai;
  document.getElementById('result-name').textContent = ai.name || 'Unknown Part';
  document.getElementById('result-meta').textContent = [
    ai.part_num ? `#${ai.part_num}` : null,
    ai.category,
    ai.color,
  ].filter(Boolean).join(' · ');
  document.getElementById('result-description').textContent = ai.description || '';
  document.getElementById('manual-part-num').value = ai.part_num || '';

  const conf = ai.confidence ?? 0.5;
  const badge = document.getElementById('confidence-badge');
  badge.className = 'confidence-badge ' + (conf >= 0.8 ? 'confidence-high' : conf >= 0.5 ? 'confidence-med' : 'confidence-low');
  badge.textContent = Math.round(conf * 100) + '%';

  const foundEl = document.getElementById('location-found');
  const newEl = document.getElementById('location-new');
  const assignEl = document.getElementById('assign-section');
  const editEl = document.getElementById('edit-section');

  if (data.location) {
    foundEl.hidden = false;
    document.getElementById('location-text').textContent = data.location.display;
    newEl.hidden = true;
    assignEl.hidden = true;
    editEl.hidden = false;
  } else {
    foundEl.hidden = true;
    newEl.hidden = false;
    assignEl.hidden = false;
    editEl.hidden = true;
  }

  const baSection = document.getElementById('brickarchitect-section');
  const partNum = ai.part_num || document.getElementById('manual-part-num').value.trim();
  if (partNum) {
    const pn = encodeURIComponent(partNum);
    document.getElementById('ba-link').href = `https://brickarchitect.com/parts/${pn}`;
    document.getElementById('ba-lbx').href = `https://brickarchitect.com/label/${pn}.lbx`;
    document.getElementById('ba-lbx-qr').href = `https://brickarchitect.com/label/${pn}-qr.lbx`;
    document.getElementById('ba-part-img').src = `https://brickarchitect.com/content/parts-large/${pn}.png`;
    document.getElementById('stl-link').href = `https://www.printables.com/search/models?q=lego+${pn}`;
    baSection.hidden = false;
  } else {
    baSection.hidden = true;
  }

  document.getElementById('identify-result').hidden = false;
}

function resetIdentify() {
  document.getElementById('upload-prompt').hidden = false;
  document.getElementById('upload-preview').hidden = true;
  document.getElementById('identify-result').hidden = true;
  document.getElementById('identify-loading').hidden = true;
  currentAi = null;
  currentPart = null;
}

let _lookupResult = null;

function clearLookupResult() {
  _lookupResult = null;
  document.getElementById('lookup-result').hidden = true;
  document.getElementById('lookup-not-found').hidden = true;
  document.getElementById('lookup-loading').hidden = true;
}

async function relookup() {
  const partNum = document.getElementById('manual-part-num').value.trim();
  if (!partNum) return;

  clearLookupResult();
  document.getElementById('lookup-loading').hidden = false;

  try {
    const res = await apiProject(`/lookup/${encodeURIComponent(partNum)}`);
    const data = await res.json();
    document.getElementById('lookup-loading').hidden = true;

    if (!data.found_on_brickarchitect) {
      document.getElementById('lookup-not-found').hidden = false;
      return;
    }

    _lookupResult = data;

    let metaParts = [`#${esc(data.part_num)}`];
    if (data.existing?.drawer_id) {
      metaParts.push(`In catalog — Cabinet ${data.existing.cabinet}·${data.existing.row}${data.existing.col}`);
    } else {
      metaParts.push('Not yet in catalog');
    }

    document.getElementById('lookup-name').textContent = data.name;
    document.getElementById('lookup-meta').textContent = metaParts.join(' · ');
    document.getElementById('lookup-ba-link').href = data.brickarchitect_url;
    document.getElementById('lookup-img').src =
      `https://brickarchitect.com/content/parts-large/${encodeURIComponent(data.part_num)}.png`;
    document.getElementById('lookup-result').hidden = false;

  } catch (err) {
    document.getElementById('lookup-loading').hidden = true;
    alert('Lookup error: ' + err.message);
  }
}

function applyLookupResult() {
  if (!_lookupResult) return;
  const data = _lookupResult;

  document.getElementById('result-name').textContent = data.name;
  document.getElementById('result-meta').textContent = [
    `#${data.part_num}`, currentAi?.category,
  ].filter(Boolean).join(' · ');
  if (currentAi) currentAi.part_num = data.part_num;

  if (data.existing?.drawer_id) {
    document.getElementById('location-found').hidden = false;
    document.getElementById('location-text').textContent =
      `Cabinet ${data.existing.cabinet} · ${data.existing.row}${data.existing.col}`;
    document.getElementById('location-new').hidden = true;
    document.getElementById('assign-section').hidden = true;
    document.getElementById('edit-section').hidden = false;
    currentPart = data.existing;
  } else {
    document.getElementById('location-found').hidden = true;
    document.getElementById('location-new').hidden = false;
    document.getElementById('assign-section').hidden = false;
    document.getElementById('edit-section').hidden = true;
    currentPart = null;
  }

  const pn = encodeURIComponent(data.part_num);
  document.getElementById('ba-link').href = `https://brickarchitect.com/parts/${pn}`;
  document.getElementById('ba-lbx').href = `https://brickarchitect.com/label/${pn}.lbx`;
  document.getElementById('ba-lbx-qr').href = `https://brickarchitect.com/label/${pn}-qr.lbx`;
  document.getElementById('ba-part-img').src = `https://brickarchitect.com/content/parts-large/${pn}.png`;
  document.getElementById('stl-link').href = `https://www.printables.com/search/models?q=lego+${pn}`;
  document.getElementById('brickarchitect-section').hidden = false;

  clearLookupResult();
  document.getElementById('manual-part-num').value = data.part_num;
}

function openEditForCurrent() {
  if (!currentPart) return;
  openEditPartModal(currentPart);
}

/* ── Drawer Picker ── */
async function openDrawerPicker() {
  await fetchDrawers();
  const ai = currentAi || {};
  openModal('Assign to Drawer', buildDrawerPickerHTML(ai));
}

function buildDrawerPickerHTML(ai) {
  const partNum = document.getElementById('manual-part-num').value.trim() || ai.part_num || '';
  const partName = ai.name || '';

  let html = `
    <div style="margin-bottom:14px;">
      <label class="form-label">Part Number</label>
      <input type="text" id="dp-part-num" class="input" value="${esc(partNum)}" placeholder="e.g. 3001">
    </div>
    <div style="margin-bottom:14px;">
      <label class="form-label">Part Name</label>
      <input type="text" id="dp-part-name" class="input" value="${esc(partName)}" placeholder="e.g. 2x4 Brick">
    </div>
    <label class="form-label">Select Drawer</label>
    <div class="drawer-picker-list" id="drawer-picker-list">
  `;

  if (allDrawers.length === 0) {
    html += `<p style="color:var(--text-muted);font-size:14px;">No drawers yet. Create one below.</p>`;
  } else {
    for (const d of allDrawers) {
      const label = drawerLabel(d);
      html += `
        <div class="drawer-option" onclick="selectDrawerOption(this, '${esc(d.id)}')" data-id="${esc(d.id)}">
          <div>
            <div class="drawer-option-id">${esc(label)}</div>
            <div class="drawer-option-meta">${esc(d.label || '')}${d.notes ? ' · ' + d.notes : ''}</div>
          </div>
          <div class="drawer-option-count">${d.part_count} part${d.part_count !== 1 ? 's' : ''}</div>
        </div>`;
    }
  }

  html += `</div>
    <div style="margin-bottom:14px;">
      <label class="form-label">Or create new drawer</label>
      <div class="new-drawer-form">
        <div class="form-row">
          <div>
            <label class="form-label">Cabinet</label>
            <input type="number" id="nd-cabinet" class="input" value="1" min="1">
          </div>
          <div>
            <label class="form-label">Row</label>
            <input type="text" id="nd-row" class="input" value="A" maxlength="2">
          </div>
          <div>
            <label class="form-label">Col</label>
            <input type="number" id="nd-col" class="input" value="1" min="1">
          </div>
        </div>
        <input type="text" id="nd-label" class="input" placeholder="Label (optional)">
        <button class="btn btn-secondary" onclick="createAndSelectDrawer()">Create Drawer</button>
      </div>
    </div>
    <div style="margin-bottom:14px;">
      <label class="form-label">Notes</label>
      <input type="text" id="dp-notes" class="input" placeholder="Optional notes">
    </div>
    <button class="btn btn-primary w-full" onclick="assignPartToDrawer()">Save</button>
  `;
  return html;
}

let selectedDrawerId = null;

function selectDrawerOption(el, drawerId) {
  document.querySelectorAll('.drawer-option').forEach(o => o.classList.remove('selected'));
  el.classList.add('selected');
  selectedDrawerId = drawerId;
}

async function createAndSelectDrawer() {
  const cabinet = parseInt(document.getElementById('nd-cabinet').value);
  const row = document.getElementById('nd-row').value.trim().toUpperCase();
  const col = parseInt(document.getElementById('nd-col').value);
  const label = document.getElementById('nd-label').value.trim() || null;

  if (!cabinet || !row || !col) { alert('Fill in Cabinet, Row, and Column.'); return; }

  try {
    const res = await apiProject('/drawers', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cabinet, row, col, label }),
    });
    if (!res.ok) throw new Error(await res.text());
    const drawer = await res.json();
    await fetchDrawers();

    const list = document.getElementById('drawer-picker-list');
    list.innerHTML = '';
    for (const d of allDrawers) {
      const lbl = drawerLabel(d);
      const div = document.createElement('div');
      div.className = 'drawer-option' + (d.id === drawer.id ? ' selected' : '');
      div.dataset.id = d.id;
      div.onclick = () => { selectDrawerOption(div, d.id); };
      div.innerHTML = `
        <div>
          <div class="drawer-option-id">${esc(lbl)}</div>
          <div class="drawer-option-meta">${esc(d.label || '')}</div>
        </div>
        <div class="drawer-option-count">${d.part_count} parts</div>
      `;
      list.appendChild(div);
    }
    selectedDrawerId = drawer.id;
  } catch (err) {
    alert('Error creating drawer: ' + err.message);
  }
}

async function assignPartToDrawer() {
  const partNum = document.getElementById('dp-part-num').value.trim();
  const partName = document.getElementById('dp-part-name').value.trim();
  const notes = document.getElementById('dp-notes').value.trim() || null;

  if (!partNum) { alert('Part number is required.'); return; }
  if (!partName) { alert('Part name is required.'); return; }
  if (!selectedDrawerId) { alert('Please select or create a drawer.'); return; }

  const body = {
    part_num: partNum,
    part_name: partName,
    category: currentAi?.category || null,
    drawer_id: selectedDrawerId,
    notes,
    ai_description: currentAi ? JSON.stringify(currentAi) : null,
  };

  try {
    const res = await apiProject('/parts', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(await res.text());
    const part = await res.json();
    const drawer = allDrawers.find(d => d.id === selectedDrawerId);
    closeModal();
    document.getElementById('location-found').hidden = false;
    document.getElementById('location-text').textContent =
      `Cabinet ${drawer.cabinet} · ${drawer.row}${drawer.col}` + (drawer.label ? ` (${drawer.label})` : '');
    document.getElementById('location-new').hidden = true;
    document.getElementById('assign-section').hidden = true;
    document.getElementById('edit-section').hidden = false;
    currentPart = part;
    selectedDrawerId = null;
  } catch (err) {
    alert('Error saving part: ' + err.message);
  }
}

/* ── Edit Part Modal ── */
function openEditPartModal(part) {
  editingPartNum = part.part_num;
  const locationStr = part.drawer_id
    ? `Cabinet ${part.cabinet} · ${part.row}${part.col}`
    : 'No drawer assigned';

  openModal('Edit Part', buildEditPartHTML(part, locationStr));
}

function buildEditPartHTML(part, locationStr) {
  return `
    ${baImgHtml(part.part_num, 'lg')}
    <div style="margin-bottom:12px;">
      <label class="form-label">Part Number</label>
      <input type="text" class="input" value="${esc(part.part_num)}" disabled style="opacity:0.6">
    </div>
    <div style="margin-bottom:12px;">
      <label class="form-label">Part Name</label>
      <input type="text" id="ep-name" class="input" value="${esc(part.part_name)}">
    </div>
    <div style="margin-bottom:12px;">
      <label class="form-label">Category</label>
      <input type="text" id="ep-category" class="input" value="${esc(part.category || '')}">
    </div>
    <div style="margin-bottom:12px;">
      <label class="form-label">Notes</label>
      <input type="text" id="ep-notes" class="input" value="${esc(part.notes || '')}">
    </div>
    <div style="margin-bottom:12px;">
      <label class="form-label">Current Location: ${esc(locationStr)}</label>
      <label class="form-label" style="margin-top:8px;">Move to Drawer</label>
      <div class="drawer-picker-list" id="edit-drawer-list" style="margin-top:6px;">
        ${allDrawers.map(d => `
          <div class="drawer-option${d.id === part.drawer_id ? ' selected' : ''}"
               onclick="selectEditDrawer(this, '${esc(d.id)}')" data-id="${esc(d.id)}">
            <div>
              <div class="drawer-option-id">${esc(drawerLabel(d))}</div>
              <div class="drawer-option-meta">${esc(d.label || '')}</div>
            </div>
            <div class="drawer-option-count">${d.part_count} parts</div>
          </div>`).join('')}
      </div>
    </div>
    <div style="display:flex;gap:8px;margin-top:4px;">
      <button class="btn btn-primary" style="flex:1" onclick="savePartEdit()">Save</button>
      <button class="btn btn-danger" onclick="deletePart('${esc(part.part_num)}')">Delete</button>
    </div>
  `;
}

let editDrawerId = null;

function selectEditDrawer(el, drawerId) {
  document.querySelectorAll('#edit-drawer-list .drawer-option').forEach(o => o.classList.remove('selected'));
  el.classList.add('selected');
  editDrawerId = drawerId;
}

async function savePartEdit() {
  const name = document.getElementById('ep-name').value.trim();
  const category = document.getElementById('ep-category').value.trim() || null;
  const notes = document.getElementById('ep-notes').value.trim() || null;

  const body = { part_name: name, category };
  if (notes !== null) body.notes = notes;
  if (editDrawerId !== null) body.drawer_id = editDrawerId;

  try {
    const res = await apiProject(`/parts/${encodeURIComponent(editingPartNum)}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(await res.text());
    closeModal();
    loadBrowse();
  } catch (err) {
    alert('Error saving: ' + err.message);
  }
}

async function deletePart(partNum) {
  if (!confirm(`Delete part ${partNum}? This cannot be undone.`)) return;
  try {
    await apiProject(`/parts/${encodeURIComponent(partNum)}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ drawer_id: null }),
    });
    closeModal();
    loadBrowse();
  } catch (err) {
    alert('Error: ' + err.message);
  }
}

/* ── Catalog search (Identify view) ── */
let _catalogTimer = null;

async function initCatalogSearch() {
  const res = await apiFetch('/api/catalog/status');
  const data = await res.json();
  const prompt = document.getElementById('catalog-load-prompt');
  if (data.parts_in_catalog === 0) {
    prompt.hidden = false;
  } else {
    prompt.hidden = true;
  }
}

function catalogSearch(val) {
  clearTimeout(_catalogTimer);
  const resultsEl = document.getElementById('catalog-search-results');
  const noResultsEl = document.getElementById('catalog-no-results');
  resultsEl.hidden = true;
  noResultsEl.hidden = true;

  if (!val || val.length < 2) return;

  _catalogTimer = setTimeout(async () => {
    const res = await apiFetch(`/api/catalog/search?q=${encodeURIComponent(val)}`);
    const results = await res.json();

    if (results.length === 0) {
      noResultsEl.hidden = false;
      return;
    }

    resultsEl.innerHTML = results.map(r => {
      const badge = r.drawer_id
        ? `<span class="catalog-result-badge catalog-badge-cataloged">In Cabinet ${r.cabinet}·${r.row}${r.col}</span>`
        : `<span class="catalog-result-badge catalog-badge-new">Not cataloged</span>`;
      return `
        <div class="catalog-result-item" onclick="selectCatalogResult('${esc(r.part_num)}', '${esc(r.name)}')">
          ${baImgHtml(r.part_num)}
          <div class="catalog-result-info">
            <div class="catalog-result-name">${esc(r.name)}</div>
            <div class="catalog-result-num">#${esc(r.part_num)}${r.part_material ? ' · ' + esc(r.part_material) : ''}</div>
          </div>
          ${badge}
        </div>`;
    }).join('');
    resultsEl.hidden = false;
  }, 300);
}

function selectCatalogResult(partNum, name) {
  document.getElementById('catalog-search-input').value = '';
  document.getElementById('catalog-search-results').hidden = true;
  document.getElementById('catalog-no-results').hidden = true;

  document.getElementById('manual-part-num').value = partNum;

  if (!document.getElementById('identify-result').hidden) {
    relookup();
  } else {
    document.getElementById('identify-result').hidden = false;
    document.getElementById('result-name').textContent = name;
    document.getElementById('result-meta').textContent = `#${partNum}`;
    document.getElementById('result-description').textContent = '';
    document.getElementById('confidence-badge').className = 'confidence-badge';
    document.getElementById('confidence-badge').textContent = '';
    document.getElementById('location-found').hidden = true;
    document.getElementById('location-new').hidden = true;
    document.getElementById('assign-section').hidden = true;
    document.getElementById('edit-section').hidden = true;
    const pn = encodeURIComponent(partNum);
    document.getElementById('ba-link').href = `https://brickarchitect.com/parts/${pn}`;
    document.getElementById('ba-lbx').href = `https://brickarchitect.com/label/${pn}.lbx`;
    document.getElementById('ba-lbx-qr').href = `https://brickarchitect.com/label/${pn}-qr.lbx`;
    document.getElementById('ba-part-img').src = `https://brickarchitect.com/content/parts-large/${pn}.png`;
    document.getElementById('stl-link').href = `https://www.printables.com/search/models?q=lego+${pn}`;
    document.getElementById('brickarchitect-section').hidden = false;
    relookup();
  }
}

async function loadCatalog() {
  const btn = document.getElementById('catalog-load-btn');
  const resultEl = document.getElementById('catalog-load-result');
  if (btn) { btn.disabled = true; btn.textContent = 'Downloading…'; }
  if (resultEl) { resultEl.hidden = false; resultEl.className = 'import-result'; resultEl.textContent = 'Downloading from Rebrickable…'; }

  try {
    const res = await apiFetch('/api/catalog/load', { method: 'POST' });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Failed');
    if (resultEl) {
      resultEl.className = 'import-result success';
      resultEl.textContent = `Loaded ${data.parts_loaded.toLocaleString()} parts.`;
    }
    document.getElementById('catalog-load-prompt').hidden = true;
    await loadDataStats();
  } catch (err) {
    if (resultEl) {
      resultEl.className = 'import-result error';
      resultEl.textContent = 'Error: ' + err.message;
    }
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Download Parts Catalog'; }
  }
}

/* ── View: Browse ── */
let searchTimer = null;

function loadBrowse() {
  searchParts();
}

async function searchParts() {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(async () => {
    const q = document.getElementById('search-input').value.trim();
    const res = await apiProject('/parts?q=' + encodeURIComponent(q));
    const parts = await res.json();
    renderPartsList(parts);
  }, 250);
}

function renderPartsList(parts) {
  const list = document.getElementById('parts-list');
  if (parts.length === 0) {
    list.innerHTML = '<p style="color:var(--text-muted);text-align:center;padding:32px 0;">No parts found</p>';
    return;
  }
  list.innerHTML = parts.map(p => `
    <div class="part-item" onclick="openEditPartModal(${JSON.stringify(p).replace(/"/g, '&quot;')})">
      ${baImgHtml(p.part_num)}
      <div class="part-info">
        <div class="part-item-name">${esc(p.part_name)}</div>
        <div class="part-item-meta">#${esc(p.part_num)}${p.category ? ' · ' + esc(p.category) : ''}</div>
      </div>
      ${p.drawer_id ? `<div class="drawer-chip">Cabinet ${p.cabinet}·${p.row}${p.col}</div>` : ''}
    </div>
  `).join('');
}

/* ── View: Drawers ── */
async function loadDrawers() {
  await fetchDrawers();
  renderDrawersGrid();
}

async function fetchDrawers() {
  const res = await apiProject('/drawers');
  allDrawers = await res.json();
}

function renderDrawersGrid() {
  const grid = document.getElementById('drawers-grid');

  if (allDrawers.length === 0) {
    grid.innerHTML = '<p style="color:var(--text-muted);text-align:center;padding:32px 0;">No drawers yet. Add one!</p>';
    return;
  }

  const byCabinet = {};
  for (const d of allDrawers) {
    if (!byCabinet[d.cabinet]) byCabinet[d.cabinet] = [];
    byCabinet[d.cabinet].push(d);
  }

  grid.innerHTML = Object.entries(byCabinet).map(([cab, drawers]) => {
    const maxCol = Math.max(...drawers.map(d => d.col));
    const rows = [...new Set(drawers.map(d => d.row))].sort();

    const existing = {};
    for (const d of drawers) existing[`${d.row}${d.col}`] = d;

    const rowsHtml = rows.map(row => {
      const tilesHtml = Array.from({length: maxCol}, (_, i) => {
        const col = i + 1;
        const d = existing[`${row}${col}`];

        if (d) {
          const occupied = d.part_count > 0;
          const cls = occupied ? 'drawer-tile occupied' : 'drawer-tile empty';
          const imgHtml = d.first_part_num
            ? `<img src="https://brickarchitect.com/content/parts-large/${encodeURIComponent(d.first_part_num)}.png"
                    class="drawer-tile-img" alt="" loading="lazy">`
            : '';
          const countLabel = occupied ? `${d.part_count} part${d.part_count !== 1 ? 's' : ''}` : 'Empty';
          return `
            <div class="${cls}" onclick="openDrawerDetail('${esc(d.id)}')">
              <div class="drawer-tile-id">${row}${col}</div>
              ${imgHtml}
              <div class="drawer-tile-count">${countLabel}</div>
              ${d.label ? `<div class="drawer-tile-label">${esc(d.label)}</div>` : ''}
            </div>`;
        } else {
          return `
            <div class="drawer-tile virtual" onclick="prefillAddDrawer('${cab}','${row}',${col})">
              <div class="drawer-tile-id">${row}${col}</div>
              <div class="drawer-tile-count">Available</div>
            </div>`;
        }
      }).join('');

      return `<div class="drawer-row-label-group">
        <div class="drawer-row-label">Row ${row}</div>
        <div class="drawer-grid-row">${tilesHtml}</div>
      </div>`;
    }).join('');

    return `<div class="cabinet-section">
      <div class="cabinet-label">Cabinet ${cab}</div>
      ${rowsHtml}
    </div>`;
  }).join('');
}

async function openDrawerDetail(drawerId) {
  const res = await apiProject(`/drawers/${drawerId}/parts`);
  const data = await res.json();
  const d = data.drawer;
  const parts = data.parts;

  const partsHtml = parts.length === 0
    ? '<p style="color:var(--text-muted);font-size:14px;">No parts in this drawer.</p>'
    : parts.map(p => `
        <div class="part-item" onclick="openEditPartModal(${JSON.stringify({...p, cabinet: d.cabinet, row: d.row, col: d.col, drawer_label: d.label}).replace(/"/g, '&quot;')})">
          ${baImgHtml(p.part_num)}
          <div class="part-info">
            <div class="part-item-name">${esc(p.part_name)}</div>
            <div class="part-item-meta">#${esc(p.part_num)}${p.category ? ' · ' + esc(p.category) : ''}</div>
          </div>
        </div>`).join('');

  openModal(`${drawerLabel(d)} — ${parts.length} part${parts.length !== 1 ? 's' : ''}`, `
    <div style="margin-bottom:8px;color:var(--text-muted);font-size:13px;">${d.label ? esc(d.label) + ' · ' : ''}${d.notes ? esc(d.notes) : ''}</div>
    <div class="card-list">${partsHtml}</div>
  `);
}

function prefillAddDrawer(cabinet, row, col) {
  openAddDrawer(cabinet, row, col);
}

function openAddDrawer(cabinet = '', row = '', col = '') {
  openModal('Add Drawer', `
    <div class="new-drawer-form">
      <div class="form-row">
        <div>
          <label class="form-label">Cabinet</label>
          <input type="number" id="add-cab" class="input" value="${cabinet || 1}" min="1">
        </div>
        <div>
          <label class="form-label">Row</label>
          <input type="text" id="add-row" class="input" value="${row || 'A'}" maxlength="2">
        </div>
        <div>
          <label class="form-label">Col</label>
          <input type="number" id="add-col" class="input" value="${col || 1}" min="1">
        </div>
      </div>
      <div>
        <label class="form-label">Label (optional)</label>
        <input type="text" id="add-label" class="input" placeholder="e.g. Small Bricks">
      </div>
      <div>
        <label class="form-label">Notes (optional)</label>
        <input type="text" id="add-notes" class="input" placeholder="e.g. 1x1, 1x2, 1x3">
      </div>
      <button class="btn btn-primary w-full" onclick="submitAddDrawer()">Add Drawer</button>
    </div>
  `);
}

async function submitAddDrawer() {
  const cabinet = parseInt(document.getElementById('add-cab').value);
  const row = document.getElementById('add-row').value.trim().toUpperCase();
  const col = parseInt(document.getElementById('add-col').value);
  const label = document.getElementById('add-label').value.trim() || null;
  const notes = document.getElementById('add-notes').value.trim() || null;

  if (!cabinet || !row || !col) { alert('Fill in all required fields.'); return; }

  try {
    const res = await apiProject('/drawers', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cabinet, row, col, label, notes }),
    });
    if (!res.ok) throw new Error(await res.text());
    closeModal();
    await loadDrawers();
  } catch (err) {
    alert('Error: ' + err.message);
  }
}

/* ── View: Data ── */
async function loadDataStats() {
  const [partsRes, drawersRes, catalogRes] = await Promise.all([
    apiProject('/parts'),
    apiProject('/drawers'),
    apiFetch('/api/catalog/status'),
  ]);
  const parts = await partsRes.json();
  const drawers = await drawersRes.json();
  const catalog = await catalogRes.json();

  document.getElementById('export-stats').innerHTML = `
    <div class="stat-box"><div class="stat-num">${parts.length}</div><div class="stat-label">Parts</div></div>
    <div class="stat-box"><div class="stat-num">${drawers.length}</div><div class="stat-label">Drawers</div></div>
  `;

  const catalogStatsEl = document.getElementById('catalog-stats');
  if (catalogStatsEl) {
    catalogStatsEl.innerHTML = catalog.parts_in_catalog > 0
      ? `<div class="stat-box"><div class="stat-num">${catalog.parts_in_catalog.toLocaleString()}</div><div class="stat-label">Parts in catalog</div></div>`
      : '';
  }

  await loadModelSelector();
  await loadProjectMembers();
}

async function loadModelSelector() {
  try {
    const res = await apiFetch('/api/models');
    const data = await res.json();

    const providerLabel = data.provider === 'bedrock' ? 'AWS Bedrock' : 'Anthropic API';
    document.getElementById('model-provider-label').textContent = `Provider: ${providerLabel}`;

    const select = document.getElementById('model-select');
    select.innerHTML = data.available.map(m =>
      `<option value="${esc(m.id)}" ${m.id === data.active ? 'selected' : ''}>${esc(m.label)}</option>`
    ).join('');
  } catch (err) {
    document.getElementById('model-provider-label').textContent = 'Could not load models';
  }
}

async function setModel(modelId) {
  try {
    const res = await apiFetch('/api/settings', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model_id: modelId }),
    });
    if (!res.ok) throw new Error(await res.text());
  } catch (err) {
    alert('Error updating model: ' + err.message);
  }
}

async function exportCatalog() {
  try {
    const res = await apiProject('/export');
    const blob = await res.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    const today = new Date().toISOString().slice(0, 10);
    a.href = url;
    a.download = `lego-catalog-${today}.json`;
    a.click();
    URL.revokeObjectURL(url);
  } catch (err) {
    alert('Export failed: ' + err.message);
  }
}

async function importCatalog(input) {
  const file = input.files[0];
  if (!file) return;

  const resultEl = document.getElementById('import-result');
  resultEl.hidden = false;
  resultEl.className = 'import-result';
  resultEl.textContent = 'Importing…';

  try {
    const text = await file.text();
    const res = await apiProject('/import', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: text,
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || JSON.stringify(data));
    resultEl.className = 'import-result success';
    resultEl.textContent = `Imported successfully — ${data.parts} parts, ${data.drawers} drawers`;
    loadDataStats();
  } catch (err) {
    resultEl.className = 'import-result error';
    resultEl.textContent = 'Import failed: ' + err.message;
  }
  input.value = '';
}

/* ── Project members ── */
async function loadProjectMembers() {
  try {
    const res = await apiFetch(`/api/projects/${currentProjectId}`);
    const proj = await res.json();
    const members = proj.members || [];
    const el = document.getElementById('project-members');
    el.innerHTML = members.map(m =>
      `<div style="font-size:13px;color:var(--text-muted);padding:4px 0;">${esc(m.email)}</div>`
    ).join('');
  } catch {}
}

async function inviteMember() {
  const email = document.getElementById('invite-email').value.trim();
  const resultEl = document.getElementById('invite-result');
  if (!email) return;

  resultEl.hidden = false;
  resultEl.className = 'import-result';
  resultEl.textContent = 'Inviting…';

  try {
    const res = await apiFetch(`/api/projects/${currentProjectId}/members`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Failed');
    resultEl.className = 'import-result success';
    resultEl.textContent = `${email} added to project.`;
    document.getElementById('invite-email').value = '';
    await loadProjectMembers();
  } catch (err) {
    resultEl.className = 'import-result error';
    resultEl.textContent = 'Error: ' + err.message;
  }
}

/* ── Modal ── */
function openModal(title, bodyHtml) {
  selectedDrawerId = null;
  editDrawerId = null;
  document.getElementById('modal-title').textContent = title;
  document.getElementById('modal-body').innerHTML = bodyHtml;
  document.getElementById('modal-overlay').hidden = false;
  document.body.style.overflow = 'hidden';
}

function closeModal() {
  document.getElementById('modal-overlay').hidden = true;
  document.body.style.overflow = '';
  editingPartNum = null;
  editDrawerId = null;
  selectedDrawerId = null;
}

/* ── Helpers ── */
function drawerLabel(d) {
  return `${d.cabinet}-${d.row}${d.col}`;
}

function baImgHtml(partNum, size = 'sm') {
  if (!partNum) return '';
  const url = `https://brickarchitect.com/content/parts-large/${encodeURIComponent(partNum)}.png`;
  const cls = size === 'lg' ? 'part-img-lg' : 'part-img-sm';
  return `<img src="${url}" class="${cls}" alt="${esc(partNum)}" loading="lazy">`;
}

function esc(str) {
  if (str == null) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}
