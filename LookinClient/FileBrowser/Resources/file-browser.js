const pending = new Map();
let requestSequence = 1;
const quickLocations = [
  { id: 'rootBtn', path: '', label: '根目录' },
  { id: 'documentsBtn', path: 'Documents', label: 'Documents' },
  { id: 'libraryBtn', path: 'Library', label: 'Library' },
  { id: 'tmpBtn', path: 'tmp', label: 'tmp' }
];
const state = { apps: [], selectedAppID: null, currentPath: '', entries: [], selectedPath: null, status: '', filterText: '', sortMode: 'kind-name', viewMode: 'list' };
const appTabs = document.getElementById('appTabs');
const pathInput = document.getElementById('pathInput');
const newFolderInput = document.getElementById('newFolderInput');
const sourceUrlInput = document.getElementById('sourceUrlInput');
const searchInput = document.getElementById('searchInput');
const sortSelect = document.getElementById('sortSelect');
const listViewBtn = document.getElementById('listViewBtn');
const gridViewBtn = document.getElementById('gridViewBtn');
const statusText = document.getElementById('statusText');
const entriesBody = document.getElementById('entriesBody');
const entriesTable = document.getElementById('entriesTable');
const gridBody = document.getElementById('gridBody');
const emptyState = document.getElementById('emptyState');
const footerPath = document.getElementById('footerPath');
const footerCount = document.getElementById('footerCount');
const breadcrumbs = document.getElementById('breadcrumbs');
const detailsCard = document.getElementById('detailsCard');
const selectionBadge = document.getElementById('selectionBadge');
const currentFolderName = document.getElementById('currentFolderName');
window.__lookinResolve = (id, value) => { const pendingRequest = pending.get(id); if (!pendingRequest) return; pending.delete(id); pendingRequest.resolve(value); };
window.__lookinReject = (id, error) => { const pendingRequest = pending.get(id); if (!pendingRequest) return; pending.delete(id); pendingRequest.reject(error); };
function callNative(action, payload = {}) { return new Promise((resolve, reject) => { const id = requestSequence++; pending.set(id, { resolve, reject }); window.webkit.messageHandlers.lookinFileBrowser.postMessage({ id, action, payload }); }); }
function messageFromError(error, fallback) { if (!error) return fallback || ''; const parts = []; if (error.message) parts.push(error.message); if (error.detail) parts.push(error.detail); if (!parts.length && fallback) parts.push(fallback); return parts.join(' '); }
function unsupportedMessage() { return 'This app must upgrade LookinServer to 1.2.8 or newer before USB file transfer can be used.'; }
function selectedApp() { return state.apps.find(item => item.id === state.selectedAppID) || null; }
function canBrowseSelectedApp() { const app = selectedApp(); return !!(app && app.supportsFileTransfer !== false); }
function setStatus(text) { state.status = text || ''; statusText.textContent = state.status || 'Ready'; }
function displayPath(path) { return path ? '/' + path : '/'; }
function parentPath(path) { if (!path) return ''; const segments = path.split('/').filter(Boolean); segments.pop(); return segments.join('/'); }
function selectedEntry() { return state.entries.find(item => item.remotePath === state.selectedPath) || null; }
function folderLabel(path) { if (!path) return '根目录'; const segments = path.split('/').filter(Boolean); return segments[segments.length - 1] || '根目录'; }
function entryKind(entry) { return entry.kind || (entry.isDirectory ? 'Folder' : 'File'); }
function entryIcon(entry) { return entry.isDirectory ? '📁' : '📄'; }
function currentLocationForPath(path) { if (!path) return 'rootBtn'; const found = quickLocations.find(item => item.path && (path === item.path || path.startsWith(item.path + '/'))); return found ? found.id : null; }
function breadcrumbsForPath(path) { const list = [{ label: '根目录', path: '' }]; const segments = path.split('/').filter(Boolean); let current = ''; segments.forEach(segment => { current = current ? current + '/' + segment : segment; list.push({ label: segment, path: current }); }); return list; }
function clearElement(node) { while (node.firstChild) node.removeChild(node.firstChild); }
function createDetailRow(label, value, mono = false) { const row = document.createElement('div'); row.className = 'detail-row'; const title = document.createElement('div'); title.className = 'detail-label'; title.textContent = label; const body = document.createElement('div'); body.className = 'detail-value' + (mono ? ' mono' : ''); body.textContent = value || '—'; row.appendChild(title); row.appendChild(body); return row; }
function normalizedSize(entry) { const value = Number(entry.fileSize); return Number.isFinite(value) ? value : 0; }
function filteredAndSortedEntries() {
  const filter = (state.filterText || '').trim().toLowerCase();
  let items = [...(state.entries || [])];
  if (filter) {
    items = items.filter(entry => {
      const haystacks = [entry.name, entry.remotePath, entry.kind].filter(Boolean).map(String).map(value => value.toLowerCase());
      return haystacks.some(value => value.includes(filter));
    });
  }
  items.sort((left, right) => {
    const leftName = (left.name || '').toLowerCase();
    const rightName = (right.name || '').toLowerCase();
    switch (state.sortMode) {
      case 'name-asc': return leftName.localeCompare(rightName);
      case 'name-desc': return rightName.localeCompare(leftName);
      case 'size-desc': return normalizedSize(right) - normalizedSize(left) || leftName.localeCompare(rightName);
      case 'size-asc': return normalizedSize(left) - normalizedSize(right) || leftName.localeCompare(rightName);
      case 'kind-name':
      default:
        if (!!left.isDirectory !== !!right.isDirectory) return left.isDirectory ? -1 : 1;
        return leftName.localeCompare(rightName);
    }
  });
  return items;
}
function renderApps() {
  clearElement(appTabs);
  if (!state.selectedAppID && state.apps.length > 0) state.selectedAppID = state.apps[0].id;
  if (!state.apps.length) { const empty = document.createElement('div'); empty.className = 'small-note'; empty.textContent = 'No USB-connected apps are available right now.'; appTabs.appendChild(empty); return; }
  state.apps.forEach(app => {
    const button = document.createElement('button');
    button.className = 'app-card' + (app.id === state.selectedAppID ? ' active' : '') + (app.supportsFileTransfer === false ? ' unsupported' : '');
    const avatar = document.createElement('span'); avatar.className = 'app-avatar'; avatar.textContent = app.supportsFileTransfer === false ? '⚠︎' : '📱';
    const meta = document.createElement('span'); meta.className = 'app-meta';
    const name = document.createElement('span'); name.className = 'app-name'; name.textContent = app.appName || app.bundleIdentifier || 'Unknown App';
    const subtitle = document.createElement('span'); subtitle.className = 'app-subtitle'; subtitle.textContent = `${app.deviceName || 'USB device'} · ${app.bundleIdentifier || 'bundle'}${app.supportsFileTransfer === false ? ' · update server' : ''}`;
    meta.appendChild(name); meta.appendChild(subtitle); button.appendChild(avatar); button.appendChild(meta);
    button.addEventListener('click', async () => { state.selectedAppID = app.id; state.selectedPath = null; if (app.supportsFileTransfer === false) { state.currentPath = ''; state.entries = []; setStatus(unsupportedMessage()); render(); return; } await openPath(''); });
    appTabs.appendChild(button);
  });
}
function renderPlaces() { const activeID = currentLocationForPath(state.currentPath); quickLocations.forEach(item => { const button = document.getElementById(item.id); button.classList.toggle('active', button.id === activeID); }); }
function renderBreadcrumbs() { clearElement(breadcrumbs); breadcrumbsForPath(state.currentPath).forEach((crumb, index, list) => { const button = document.createElement('button'); button.className = 'breadcrumb secondary' + (index === list.length - 1 ? ' current' : ''); button.textContent = crumb.label; button.addEventListener('click', () => openPath(crumb.path)); breadcrumbs.appendChild(button); }); }
function renderList(items) {
  clearElement(entriesBody);
  items.forEach(entry => {
    const row = document.createElement('tr');
    if (entry.remotePath === state.selectedPath) row.classList.add('selected');
    row.addEventListener('click', () => { state.selectedPath = entry.remotePath; render(); });
    row.addEventListener('dblclick', () => { if (entry.isDirectory) openPath(entry.remotePath); });
    const nameCell = document.createElement('td');
    const nameWrap = document.createElement('div'); nameWrap.className = 'name-cell';
    const icon = document.createElement('span'); icon.className = 'entry-icon'; icon.textContent = entryIcon(entry);
    const nameBlock = document.createElement('div'); nameBlock.className = 'entry-name-block';
    const name = document.createElement('div'); name.className = 'entry-name'; name.textContent = entry.name || 'Untitled';
    const subtitle = document.createElement('div'); subtitle.className = 'entry-subtitle'; subtitle.textContent = entry.isDirectory ? 'Double-click to open' : 'Remote sandbox item';
    nameBlock.appendChild(name); nameBlock.appendChild(subtitle); nameWrap.appendChild(icon); nameWrap.appendChild(nameBlock); nameCell.appendChild(nameWrap);
    const kindCell = document.createElement('td'); kindCell.textContent = entryKind(entry);
    const sizeCell = document.createElement('td'); sizeCell.textContent = entry.sizeText || (entry.isDirectory ? '—' : 'Unknown');
    const pathCell = document.createElement('td'); pathCell.className = 'mono'; pathCell.textContent = entry.remotePath || '';
    row.appendChild(nameCell); row.appendChild(kindCell); row.appendChild(sizeCell); row.appendChild(pathCell); entriesBody.appendChild(row);
  });
}
function renderGrid(items) {
  clearElement(gridBody);
  items.forEach(entry => {
    const card = document.createElement('div');
    card.className = 'grid-card' + (entry.remotePath === state.selectedPath ? ' selected' : '');
    card.addEventListener('click', () => { state.selectedPath = entry.remotePath; render(); });
    card.addEventListener('dblclick', () => { if (entry.isDirectory) openPath(entry.remotePath); });
    const icon = document.createElement('div'); icon.className = 'grid-icon'; icon.textContent = entryIcon(entry);
    const name = document.createElement('div'); name.className = 'grid-name'; name.textContent = entry.name || 'Untitled';
    const kind = document.createElement('div'); kind.className = 'muted'; kind.textContent = entryKind(entry);
    const meta = document.createElement('div'); meta.className = 'grid-meta'; meta.textContent = entry.isDirectory ? (entry.remotePath || '') : `${entry.sizeText || 'Unknown'} · ${entry.remotePath || ''}`;
    card.appendChild(icon); card.appendChild(name); card.appendChild(kind); card.appendChild(meta); gridBody.appendChild(card);
  });
}
function renderEntries() {
  const items = filteredAndSortedEntries();
  renderList(items);
  renderGrid(items);
  entriesTable.classList.toggle('hidden', state.viewMode !== 'list');
  gridBody.classList.toggle('hidden', state.viewMode !== 'grid');
  const app = selectedApp(); const unsupported = !!(app && app.supportsFileTransfer === false);
  emptyState.hidden = state.apps.length > 0 && items.length > 0 && !unsupported;
  if (!state.apps.length) emptyState.innerHTML = '<div><strong>No USB-connected iOS app</strong><div>Plug in a device, launch the target app, then reload the connected apps list.</div></div>';
  else if (unsupported) emptyState.innerHTML = `<div><strong>File transfer unavailable</strong><div>${unsupportedMessage()}</div></div>`;
  else if (state.filterText && !items.length) emptyState.innerHTML = '<div><strong>No matching files</strong><div>Try another search term or clear the current filter.</div></div>';
  else if (!items.length) emptyState.innerHTML = '<div><strong>This folder is empty</strong><div>Try uploading a file, importing a URL, or create a new folder here.</div></div>';
  return items;
}
function renderDetails() {
  clearElement(detailsCard);
  const app = selectedApp(); const entry = selectedEntry();
  const hero = document.createElement('div'); hero.className = 'details-hero';
  const icon = document.createElement('div'); icon.className = 'details-icon';
  const textWrap = document.createElement('div');
  const title = document.createElement('div'); title.className = 'details-title';
  const subtitle = document.createElement('div'); subtitle.className = 'details-subtitle';
  if (entry) { icon.textContent = entryIcon(entry); title.textContent = entry.name || 'Untitled'; subtitle.textContent = entryKind(entry); }
  else if (app) { icon.textContent = '🗂'; title.textContent = folderLabel(state.currentPath); subtitle.textContent = 'Current location'; }
  else { icon.textContent = '📂'; title.textContent = 'Nothing selected'; subtitle.textContent = 'Pick an app to browse its sandbox'; }
  textWrap.appendChild(title); textWrap.appendChild(subtitle); hero.appendChild(icon); hero.appendChild(textWrap); detailsCard.appendChild(hero);
  const grid = document.createElement('div'); grid.className = 'detail-grid';
  if (entry) {
    grid.appendChild(createDetailRow('Path', displayPath(entry.remotePath || ''), true));
    grid.appendChild(createDetailRow('Kind', entryKind(entry)));
    grid.appendChild(createDetailRow('Size', entry.sizeText || (entry.isDirectory ? 'Folder' : 'Unknown')));
    if (app) { grid.appendChild(createDetailRow('App', app.appName || app.bundleIdentifier || 'Unknown App')); grid.appendChild(createDetailRow('Device', app.deviceName || 'USB device')); }
  } else if (app) {
    grid.appendChild(createDetailRow('Current Path', displayPath(state.currentPath), true));
    grid.appendChild(createDetailRow('Items', `${state.entries.length} item${state.entries.length === 1 ? '' : 's'}`));
    grid.appendChild(createDetailRow('View', state.viewMode === 'grid' ? 'Grid view' : 'List view'));
    grid.appendChild(createDetailRow('Sort', sortSelect.options[sortSelect.selectedIndex].textContent.replace('Sort: ', '')));
    grid.appendChild(createDetailRow('App', app.appName || app.bundleIdentifier || 'Unknown App'));
  } else { grid.appendChild(createDetailRow('Hint', 'Use the left sidebar to choose a connected app.')); }
  detailsCard.appendChild(grid);
  const actions = document.createElement('div'); actions.className = 'detail-actions';
  if (entry && entry.isDirectory) { const openButton = document.createElement('button'); openButton.className = 'secondary'; openButton.textContent = '打开文件夹'; openButton.addEventListener('click', () => openPath(entry.remotePath || '')); actions.appendChild(openButton); }
  if (entry && !entry.isDirectory) { const downloadButton = document.createElement('button'); downloadButton.className = 'secondary'; downloadButton.textContent = '下载文件'; downloadButton.addEventListener('click', downloadSelected); actions.appendChild(downloadButton); }
  if (entry) { const deleteButton = document.createElement('button'); deleteButton.className = 'danger'; deleteButton.textContent = '删除'; deleteButton.addEventListener('click', deleteSelected); actions.appendChild(deleteButton); }
  if (actions.childNodes.length) detailsCard.appendChild(actions);
  const note = document.createElement('div'); note.className = 'small-note'; note.textContent = entry ? (entry.isDirectory ? 'Tip: double-click a folder to drill into it. Grid view works too.' : 'Use the toolbar or the buttons above for quick actions on the selected file.') : 'The inspector updates when you select a file or folder.'; detailsCard.appendChild(note);
}
function renderStatusBadge(visibleItems) {
  const app = selectedApp(); const entry = selectedEntry(); selectionBadge.classList.toggle('active', !!app);
  if (!app) selectionBadge.textContent = 'No app selected';
  else if (app.supportsFileTransfer === false) selectionBadge.textContent = 'Transfer unavailable';
  else if (entry) selectionBadge.textContent = entry.isDirectory ? 'Folder selected' : 'File selected';
  else if (state.filterText) selectionBadge.textContent = `${visibleItems.length} filtered result${visibleItems.length === 1 ? '' : 's'}`;
  else selectionBadge.textContent = `${visibleItems.length} item${visibleItems.length === 1 ? '' : 's'} in view`;
}
function render() {
  renderApps(); renderPlaces(); renderBreadcrumbs();
  const visibleItems = renderEntries();
  renderDetails(); renderStatusBadge(visibleItems);
  const app = selectedApp(); const entry = selectedEntry();
  pathInput.value = state.currentPath; searchInput.value = state.filterText; sortSelect.value = state.sortMode;
  footerPath.textContent = displayPath(state.currentPath); footerCount.textContent = `${visibleItems.length} item${visibleItems.length === 1 ? '' : 's'}`; currentFolderName.textContent = folderLabel(state.currentPath);
  const browseEnabled = !!state.selectedAppID && canBrowseSelectedApp();
  listViewBtn.classList.toggle('active-toggle', state.viewMode === 'list');
  gridViewBtn.classList.toggle('active-toggle', state.viewMode === 'grid');
  document.getElementById('openPathBtn').disabled = !browseEnabled;
  document.getElementById('upBtn').disabled = !browseEnabled;
  document.getElementById('refreshBtn').disabled = !browseEnabled;
  document.getElementById('newFolderBtn').disabled = !browseEnabled;
  document.getElementById('uploadBtn').disabled = !browseEnabled;
  document.getElementById('importUrlBtn').disabled = !browseEnabled;
  document.getElementById('downloadBtn').disabled = !entry || entry.isDirectory;
  document.getElementById('deleteBtn').disabled = !entry;
  if (!state.status) {
    if (!app) statusText.textContent = 'Choose a connected app to start browsing.';
    else if (app.supportsFileTransfer === false) statusText.textContent = unsupportedMessage();
    else if (entry) statusText.textContent = `${entryKind(entry)} selected at ${displayPath(entry.remotePath || '')}`;
    else if (state.filterText) statusText.textContent = `Filtering ${visibleItems.length} result${visibleItems.length === 1 ? '' : 's'} inside ${displayPath(state.currentPath)}.`;
    else statusText.textContent = `Browsing ${displayPath(state.currentPath)} in ${app.appName || app.bundleIdentifier || 'the selected app'}.`;
  }
}
async function bootstrap(remotePath = '') { try { setStatus('Loading apps…'); const result = await callNative('bootstrap', { appID: state.selectedAppID, remotePath }); state.apps = result.apps || []; state.selectedAppID = result.selectedAppID || (state.apps[0] ? state.apps[0].id : null); state.currentPath = result.currentPath || ''; state.entries = result.items || []; state.selectedPath = null; setStatus(result.statusMessage || (state.apps.length ? '' : 'No USB-connected iOS app found.')); render(); } catch (error) { setStatus(messageFromError(error, 'Failed to load apps.')); render(); } }
async function openPath(remotePath) { if (!state.selectedAppID) { setStatus('Select a USB app first.'); render(); return; } if (!canBrowseSelectedApp()) { state.entries = []; state.currentPath = remotePath || ''; state.selectedPath = null; setStatus(unsupportedMessage()); render(); return; } try { setStatus(`Opening ${displayPath(remotePath)}…`); const result = await callNative('listDirectory', { appID: state.selectedAppID, remotePath }); state.currentPath = result.currentPath || remotePath || ''; state.entries = result.items || []; state.selectedPath = null; setStatus(''); render(); } catch (error) { setStatus(messageFromError(error, 'Failed to open directory.')); render(); } }
async function createFolder() { const name = (newFolderInput.value || '').trim(); if (!name) { setStatus('Enter a folder name first.'); render(); return; } try { setStatus('Creating folder…'); await callNative('createDirectory', { appID: state.selectedAppID, parentPath: state.currentPath, name }); newFolderInput.value = ''; await openPath(state.currentPath); setStatus('Folder created.'); render(); } catch (error) { setStatus(messageFromError(error, 'Failed to create folder.')); render(); } }
async function uploadFile() { if (!state.selectedAppID) { setStatus('Select a USB app first.'); render(); return; } try { setStatus('Selecting local file…'); await callNative('uploadFile', { appID: state.selectedAppID, directoryPath: state.currentPath }); await openPath(state.currentPath); setStatus('Upload finished.'); render(); } catch (error) { setStatus(messageFromError(error, 'Upload failed.')); render(); } }
async function importURL() { const sourceURL = (sourceUrlInput.value || '').trim(); if (!sourceURL) { setStatus('Enter a macOS URL first.'); render(); return; } if (!state.selectedAppID) { setStatus('Select a USB app first.'); render(); return; } try { setStatus('Downloading from Mac URL…'); await callNative('importURL', { appID: state.selectedAppID, directoryPath: state.currentPath, sourceURL }); await openPath(state.currentPath); setStatus('URL import finished.'); render(); } catch (error) { setStatus(messageFromError(error, 'Import failed.')); render(); } }
async function downloadSelected() { const entry = selectedEntry(); if (!entry || entry.isDirectory) { setStatus('Select a file first.'); render(); return; } try { setStatus('Saving file…'); await callNative('downloadFile', { appID: state.selectedAppID, remotePath: entry.remotePath }); setStatus('Download finished.'); render(); } catch (error) { setStatus(messageFromError(error, 'Download failed.')); render(); } }
async function deleteSelected() { const entry = selectedEntry(); if (!entry) { setStatus('Select an item first.'); render(); return; } try { setStatus('Deleting item…'); await callNative('removeItem', { appID: state.selectedAppID, remotePath: entry.remotePath }); await openPath(state.currentPath); setStatus('Delete finished.'); render(); } catch (error) { setStatus(messageFromError(error, 'Delete failed.')); render(); } }
document.getElementById('reloadAppsBtn').addEventListener('click', () => bootstrap(state.currentPath));
document.getElementById('rootBtn').addEventListener('click', () => openPath(''));
document.getElementById('documentsBtn').addEventListener('click', () => openPath('Documents'));
document.getElementById('libraryBtn').addEventListener('click', () => openPath('Library'));
document.getElementById('tmpBtn').addEventListener('click', () => openPath('tmp'));
document.getElementById('openPathBtn').addEventListener('click', () => openPath((pathInput.value || '').trim()));
document.getElementById('upBtn').addEventListener('click', () => openPath(parentPath(state.currentPath)));
document.getElementById('refreshBtn').addEventListener('click', () => openPath(state.currentPath));
document.getElementById('newFolderBtn').addEventListener('click', createFolder);
document.getElementById('uploadBtn').addEventListener('click', uploadFile);
document.getElementById('importUrlBtn').addEventListener('click', importURL);
document.getElementById('downloadBtn').addEventListener('click', downloadSelected);
document.getElementById('deleteBtn').addEventListener('click', deleteSelected);
listViewBtn.addEventListener('click', () => { state.viewMode = 'list'; render(); });
gridViewBtn.addEventListener('click', () => { state.viewMode = 'grid'; render(); });
searchInput.addEventListener('input', event => { state.filterText = event.target.value || ''; render(); });
sortSelect.addEventListener('change', event => { state.sortMode = event.target.value || 'kind-name'; render(); });
pathInput.addEventListener('keydown', event => { if (event.key === 'Enter') { event.preventDefault(); openPath((pathInput.value || '').trim()); } });
newFolderInput.addEventListener('keydown', event => { if (event.key === 'Enter') { event.preventDefault(); createFolder(); } });
sourceUrlInput.addEventListener('keydown', event => { if (event.key === 'Enter') { event.preventDefault(); importURL(); } });
searchInput.addEventListener('keydown', event => { if (event.key === 'Escape') { state.filterText = ''; searchInput.value = ''; render(); } });
bootstrap('');
