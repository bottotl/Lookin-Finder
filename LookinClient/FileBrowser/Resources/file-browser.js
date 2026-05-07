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
const sidebarStatus = document.getElementById('sidebarStatus');
const targetAppName = document.getElementById('targetAppName');
const targetDeviceName = document.getElementById('targetDeviceName');
const currentPathSummary = document.getElementById('currentPathSummary');
const currentFolderSummary = document.getElementById('currentFolderSummary');
const selectedItemSummary = document.getElementById('selectedItemSummary');
const selectedItemPath = document.getElementById('selectedItemPath');
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
function entryKind(entry) { return entry.kind || (entry.isDirectory ? '文件夹' : '文件'); }
function entryIcon(entry) { return entry.isDirectory ? 'DIR' : 'FILE'; }
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
  if (!state.apps.length) { const empty = document.createElement('div'); empty.className = 'small-note'; empty.textContent = '当前没有可用的 USB App。'; appTabs.appendChild(empty); return; }
  state.apps.forEach(app => {
    const button = document.createElement('button');
    button.className = 'app-card' + (app.id === state.selectedAppID ? ' active' : '') + (app.supportsFileTransfer === false ? ' unsupported' : '');
    const avatar = document.createElement('span'); avatar.className = 'app-avatar'; avatar.textContent = app.supportsFileTransfer === false ? '!' : 'iOS';
    const meta = document.createElement('span'); meta.className = 'app-meta';
    const name = document.createElement('span'); name.className = 'app-name'; name.textContent = app.appName || app.bundleIdentifier || '未知 App';
    const subtitle = document.createElement('span'); subtitle.className = 'app-subtitle'; subtitle.textContent = `${app.deviceName || 'USB 设备'} · ${app.bundleIdentifier || 'bundle'}${app.supportsFileTransfer === false ? ' · 需升级服务端' : ''}`;
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
    const subtitle = document.createElement('div'); subtitle.className = 'entry-subtitle'; subtitle.textContent = entry.isDirectory ? '双击打开文件夹' : 'iOS 沙盒文件';
    nameBlock.appendChild(name); nameBlock.appendChild(subtitle); nameWrap.appendChild(icon); nameWrap.appendChild(nameBlock); nameCell.appendChild(nameWrap);
    const kindCell = document.createElement('td'); kindCell.textContent = entryKind(entry);
    const sizeCell = document.createElement('td'); sizeCell.textContent = entry.sizeText || (entry.isDirectory ? '-' : '未知');
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
    const meta = document.createElement('div'); meta.className = 'grid-meta'; meta.textContent = entry.isDirectory ? (entry.remotePath || '') : `${entry.sizeText || '未知'} · ${entry.remotePath || ''}`;
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
  if (!state.apps.length) emptyState.innerHTML = '<div><strong>没有 USB iOS App</strong><div>连接设备并启动目标 App 后，点击左侧刷新。</div></div>';
  else if (unsupported) emptyState.innerHTML = `<div><strong>当前 App 不支持文件传输</strong><div>${unsupportedMessage()}</div></div>`;
  else if (state.filterText && !items.length) emptyState.innerHTML = '<div><strong>没有匹配文件</strong><div>换一个关键词，或清空搜索条件。</div></div>';
  else if (!items.length) emptyState.innerHTML = '<div><strong>当前目录为空</strong><div>可以上传文件、从 URL 导入，或创建新文件夹。</div></div>';
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
  if (entry) { icon.textContent = entryIcon(entry); title.textContent = entry.name || '未命名'; subtitle.textContent = entryKind(entry); }
  else if (app) { icon.textContent = 'DIR'; title.textContent = folderLabel(state.currentPath); subtitle.textContent = '当前目录'; }
  else { icon.textContent = 'DIR'; title.textContent = '未选择'; subtitle.textContent = '选择一个 App 开始浏览'; }
  textWrap.appendChild(title); textWrap.appendChild(subtitle); hero.appendChild(icon); hero.appendChild(textWrap); detailsCard.appendChild(hero);
  const grid = document.createElement('div'); grid.className = 'detail-grid';
  if (entry) {
    grid.appendChild(createDetailRow('路径', displayPath(entry.remotePath || ''), true));
    grid.appendChild(createDetailRow('类型', entryKind(entry)));
    grid.appendChild(createDetailRow('大小', entry.sizeText || (entry.isDirectory ? '文件夹' : '未知')));
    if (app) { grid.appendChild(createDetailRow('App', app.appName || app.bundleIdentifier || '未知 App')); grid.appendChild(createDetailRow('设备', app.deviceName || 'USB 设备')); }
  } else if (app) {
    grid.appendChild(createDetailRow('当前路径', displayPath(state.currentPath), true));
    grid.appendChild(createDetailRow('项目数', `${state.entries.length} 项`));
    grid.appendChild(createDetailRow('视图', state.viewMode === 'grid' ? '网格' : '列表'));
    grid.appendChild(createDetailRow('排序', sortSelect.options[sortSelect.selectedIndex].textContent));
    grid.appendChild(createDetailRow('App', app.appName || app.bundleIdentifier || '未知 App'));
  } else { grid.appendChild(createDetailRow('提示', '从左侧选择一个已连接的 App。')); }
  detailsCard.appendChild(grid);
  const actions = document.createElement('div'); actions.className = 'detail-actions';
  if (entry && entry.isDirectory) { const openButton = document.createElement('button'); openButton.className = 'secondary'; openButton.textContent = '打开文件夹'; openButton.addEventListener('click', () => openPath(entry.remotePath || '')); actions.appendChild(openButton); }
  if (entry && !entry.isDirectory) { const downloadButton = document.createElement('button'); downloadButton.className = 'secondary'; downloadButton.textContent = '下载到 Mac'; downloadButton.addEventListener('click', downloadSelected); actions.appendChild(downloadButton); }
  if (entry) { const deleteButton = document.createElement('button'); deleteButton.className = 'danger'; deleteButton.textContent = '删除'; deleteButton.addEventListener('click', deleteSelected); actions.appendChild(deleteButton); }
  if (actions.childNodes.length) detailsCard.appendChild(actions);
  const note = document.createElement('div'); note.className = 'small-note'; note.textContent = entry ? (entry.isDirectory ? '双击文件夹也可以进入。' : '下载会把 iOS 沙盒文件保存到 Mac。') : '选中文件或文件夹后，这里会显示可用操作。'; detailsCard.appendChild(note);
}
function renderStatusBadge(visibleItems) {
  const app = selectedApp(); const entry = selectedEntry(); selectionBadge.classList.toggle('active', !!app);
  if (!app) selectionBadge.textContent = '未选择 App';
  else if (app.supportsFileTransfer === false) selectionBadge.textContent = '不可传输';
  else if (entry) selectionBadge.textContent = entry.isDirectory ? '已选文件夹' : '已选文件';
  else if (state.filterText) selectionBadge.textContent = `${visibleItems.length} 个匹配项`;
  else selectionBadge.textContent = `${visibleItems.length} 项`;
}
function renderContextSummary(visibleItems) {
  const app = selectedApp();
  const entry = selectedEntry();
  targetAppName.textContent = app ? (app.appName || app.bundleIdentifier || '未知 App') : '未选择';
  targetDeviceName.textContent = app ? `${app.deviceName || 'USB 设备'} · ${app.bundleIdentifier || 'bundle'}` : 'USB 设备';
  currentPathSummary.textContent = displayPath(state.currentPath);
  currentFolderSummary.textContent = app ? `${visibleItems.length} 项可见` : '选择 App 后显示';
  selectedItemSummary.textContent = entry ? (entry.name || '未命名') : '无';
  selectedItemPath.textContent = entry ? displayPath(entry.remotePath || '') : '未选择';
  sidebarStatus.textContent = app ? `${app.appName || app.bundleIdentifier || '未知 App'} · ${displayPath(state.currentPath)}` : '未选择 App';
}
function render() {
  renderApps(); renderPlaces(); renderBreadcrumbs();
  const visibleItems = renderEntries();
  renderDetails(); renderStatusBadge(visibleItems);
  renderContextSummary(visibleItems);
  const app = selectedApp(); const entry = selectedEntry();
  pathInput.value = state.currentPath; searchInput.value = state.filterText; sortSelect.value = state.sortMode;
  footerPath.textContent = displayPath(state.currentPath); footerCount.textContent = `${visibleItems.length} 项`; currentFolderName.textContent = folderLabel(state.currentPath);
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
    if (!app) statusText.textContent = '选择左侧 USB App 后开始浏览。';
    else if (app.supportsFileTransfer === false) statusText.textContent = unsupportedMessage();
    else if (entry) statusText.textContent = `已选择${entryKind(entry)}：${displayPath(entry.remotePath || '')}`;
    else if (state.filterText) statusText.textContent = `在 ${displayPath(state.currentPath)} 中找到 ${visibleItems.length} 个匹配项。`;
    else statusText.textContent = `正在浏览 ${app.appName || app.bundleIdentifier || '当前 App'} 的 ${displayPath(state.currentPath)}。`;
  }
}
async function bootstrap(remotePath = '') { try { setStatus('正在加载 App…'); const result = await callNative('bootstrap', { appID: state.selectedAppID, remotePath }); state.apps = result.apps || []; state.selectedAppID = result.selectedAppID || (state.apps[0] ? state.apps[0].id : null); state.currentPath = result.currentPath || ''; state.entries = result.items || []; state.selectedPath = null; setStatus(result.statusMessage || (state.apps.length ? '' : '没有找到 USB iOS App。')); render(); } catch (error) { setStatus(messageFromError(error, '加载 App 失败。')); render(); } }
async function openPath(remotePath) { if (!state.selectedAppID) { setStatus('请先选择一个 USB App。'); render(); return; } if (!canBrowseSelectedApp()) { state.entries = []; state.currentPath = remotePath || ''; state.selectedPath = null; setStatus(unsupportedMessage()); render(); return; } try { setStatus(`正在打开 ${displayPath(remotePath)}…`); const result = await callNative('listDirectory', { appID: state.selectedAppID, remotePath }); state.currentPath = result.currentPath || remotePath || ''; state.entries = result.items || []; state.selectedPath = null; setStatus(''); render(); } catch (error) { setStatus(messageFromError(error, '打开目录失败。')); render(); } }
async function createFolder() { const name = (newFolderInput.value || '').trim(); if (!name) { setStatus('请先输入文件夹名称。'); render(); return; } try { setStatus('正在创建文件夹…'); await callNative('createDirectory', { appID: state.selectedAppID, parentPath: state.currentPath, name }); newFolderInput.value = ''; await openPath(state.currentPath); setStatus('文件夹已创建。'); render(); } catch (error) { setStatus(messageFromError(error, '创建文件夹失败。')); render(); } }
async function uploadFile() { if (!state.selectedAppID) { setStatus('请先选择一个 USB App。'); render(); return; } try { setStatus('请选择 Mac 本地文件…'); await callNative('uploadFile', { appID: state.selectedAppID, directoryPath: state.currentPath }); await openPath(state.currentPath); setStatus('文件已上传到当前 iOS 沙盒目录。'); render(); } catch (error) { setStatus(messageFromError(error, '上传失败。')); render(); } }
async function importURL() { const sourceURL = (sourceUrlInput.value || '').trim(); if (!sourceURL) { setStatus('请先输入文件 URL。'); render(); return; } if (!state.selectedAppID) { setStatus('请先选择一个 USB App。'); render(); return; } try { setStatus('正在从 URL 导入到 iOS 沙盒…'); await callNative('importURL', { appID: state.selectedAppID, directoryPath: state.currentPath, sourceURL }); await openPath(state.currentPath); setStatus('URL 文件已导入到当前目录。'); render(); } catch (error) { setStatus(messageFromError(error, '导入失败。')); render(); } }
async function downloadSelected() { const entry = selectedEntry(); if (!entry || entry.isDirectory) { setStatus('请先选择一个文件。'); render(); return; } try { setStatus('请选择保存到 Mac 的位置…'); await callNative('downloadFile', { appID: state.selectedAppID, remotePath: entry.remotePath }); setStatus('文件已下载到 Mac。'); render(); } catch (error) { setStatus(messageFromError(error, '下载失败。')); render(); } }
async function deleteSelected() { const entry = selectedEntry(); if (!entry) { setStatus('请先选择一个项目。'); render(); return; } const itemName = entry.name || entry.remotePath || '选中项'; if (!window.confirm(`确定要从 iOS 沙盒删除“${itemName}”吗？\n\n路径：${displayPath(entry.remotePath || '')}`)) { setStatus('已取消删除。'); render(); return; } try { setStatus('正在删除选中项…'); await callNative('removeItem', { appID: state.selectedAppID, remotePath: entry.remotePath }); await openPath(state.currentPath); setStatus('选中项已删除。'); render(); } catch (error) { setStatus(messageFromError(error, '删除失败。')); render(); } }
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
