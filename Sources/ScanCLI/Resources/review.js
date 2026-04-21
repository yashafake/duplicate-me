const config = window.DUPLICATEME_CONFIG;
const state = {
  session: null,
  selectedIds: new Set(),
  collapsedClusterIds: new Set(),
  activeFilter: "all",
  search: "",
  notice: null,
  chosenLocations: [],
  autoSelectMode: "smart",
  similarAutoSelectMode: "smart",
  scanOptions: {
    scanDuplicates: true,
    scanSimilarImages: false,
    scanSimilarVideos: false,
    scanSimilarAudio: false,
    includeHidden: false,
  },
  scanBusy: false,
  pickBusy: false,
  serverAvailable: true,
};
let scanPollHandle = null;

const app = document.querySelector("#app");

boot().catch((error) => {
  app.innerHTML = `<div class="empty-state"><h2>Viewer failed to load</h2><p>${escapeHtml(error.message)}</p></div>`;
});

async function boot() {
  await loadSession({ resetSelection: true });
  render();
}

async function loadSession({ resetSelection = false } = {}) {
  const session = await apiFetchJSON("/api/session", { cache: "no-store" });
  const transition = applySession(session, { resetSelection });
  syncScanPolling();

  if (transition.finishedScanning) {
    if (session.scanErrorMessage) {
      state.notice = { kind: "error", message: session.scanErrorMessage };
    } else if (session.currentRun?.runID) {
      state.notice = { kind: "success", message: `Scan finished. Loaded run ${session.currentRun.runID}.` };
    } else {
      state.notice = { kind: "error", message: "Scan finished, but no run could be loaded." };
    }
  }
}

async function apiFetch(path, options = {}) {
  try {
    const response = await fetch(path, options);
    state.serverAvailable = true;
    return response;
  } catch (error) {
    state.serverAvailable = false;
    throw offlineError(error);
  }
}

async function apiFetchJSON(path, options = {}) {
  const response = await apiFetch(path, options);
  const text = await response.text();
  let payload = null;

  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = null;
    }
  }

  if (!response.ok) {
    throw new Error(payload?.message || `Request failed with ${response.status}`);
  }

  return payload;
}

function offlineError(cause) {
  const port = window.location.port || "auto";
  const message = `Viewer server is offline. Restart it with: swift run duplicate-me serve --port ${port}`;
  const error = new Error(message);
  error.cause = cause;
  return error;
}

function applySession(session, { resetSelection = false } = {}) {
  const previousRunId = state.session?.currentRun?.runID ?? null;
  const previousScanning = state.session?.isScanning ?? false;
  state.session = session;
  state.scanBusy = session.isScanning;
  state.chosenLocations = session.selectedLocations ?? [];

  const run = currentRun();
  if (!run) {
    if (resetSelection) {
      state.selectedIds.clear();
      state.collapsedClusterIds.clear();
    }
    return {
      finishedScanning: previousScanning && !session.isScanning,
      previousRunId,
      currentRunId: null,
    };
  }

  state.scanOptions = { ...state.scanOptions, ...run.options };
  const currentRunId = run.runID;
  if (resetSelection || previousRunId !== currentRunId) {
    seedSelection(run);
    state.collapsedClusterIds.clear();
  }
  return {
    finishedScanning: previousScanning && !session.isScanning,
    previousRunId,
    currentRunId,
  };
}

function seedSelection(run) {
  state.selectedIds = buildSelectionForRun(run, state.autoSelectMode);
}

function currentRun() {
  return state.session?.currentRun ?? null;
}

function fileMapById() {
  return new Map((currentRun()?.files ?? []).map((file) => [file.id, file]));
}

function visibleClusters() {
  const run = currentRun();
  if (!run) return [];

  const query = state.search.trim().toLowerCase();
  const fileMap = fileMapById();
  const duplicateClusters = run.duplicateClusters.map((cluster) => ({ ...cluster, type: "duplicate" }));
  const similarClusters = run.similarClusters.map((cluster) => ({ ...cluster, type: "similar" }));

  return [...duplicateClusters, ...similarClusters].filter((cluster) => {
    if (state.activeFilter === "duplicates" && cluster.type !== "duplicate") return false;
    if (state.activeFilter === "similar" && cluster.type !== "similar") return false;
    if (!query) return true;

    return cluster.id.toLowerCase().includes(query) || cluster.memberIDs.some((id) => {
      const file = fileMap.get(id);
      return file && file.path.toLowerCase().includes(query);
    });
  });
}

function render() {
  const scrollState = captureScrollState();
  const run = currentRun();
  const clusters = visibleClusters();
  const fileMap = fileMapById();
  const selectedFiles = [...state.selectedIds].map((id) => fileMap.get(id)).filter(Boolean);
  const selectedBytes = selectedFiles.reduce((sum, file) => sum + file.size, 0);

  app.innerHTML = `
    <div class="shell">
      <aside class="sidebar">
        <div class="sidebar-header">
          <div class="eyebrow">Local review session</div>
          <div class="title-row">
            <div>
              <h1>DuplicateMe Viewer</h1>
              <div class="subtitle">${run
                ? `Run ${escapeHtml(run.runID)} is loaded. Review clusters or launch a new scan from here.`
                : "Choose folders, start a scan, and review the results without leaving the browser."}</div>
            </div>
          </div>

          <div class="scan-panel">
            <div class="scan-panel-header">
              <strong>Scan Setup</strong>
              <div class="selection-actions">
                <button class="ghost-button" data-action="pick-folders" ${state.pickBusy || state.scanBusy || !state.serverAvailable ? "disabled" : ""}>
                  ${state.pickBusy ? "Choosing..." : "Choose Folders"}
                </button>
                ${run ? `<button class="ghost-button" data-action="reuse-run-locations" ${state.scanBusy || !state.serverAvailable ? "disabled" : ""}>Use Current Run Folders</button>` : ""}
              </div>
            </div>

            <div class="location-list">
              ${state.chosenLocations.length
                ? state.chosenLocations.map((path) => `<span class="location-chip">${escapeHtml(path)}</span>`).join("")
                : `<span class="location-chip muted">No folders selected yet</span>`}
            </div>

            <div class="option-list">
              ${optionToggle("scanDuplicates", "Exact duplicates")}
              ${optionToggle("scanSimilarImages", "Similar images")}
              ${optionToggle("scanSimilarVideos", "Similar videos")}
              ${optionToggle("scanSimilarAudio", "Same audio across files (slower)")}
              ${optionToggle("includeHidden", "Include hidden files")}
            </div>

            <div class="selection-actions">
              <button class="action-button" data-action="start-scan" ${state.scanBusy || !state.chosenLocations.length || !state.serverAvailable ? "disabled" : ""}>
                ${state.scanBusy ? "Scanning..." : "Start Scan"}
              </button>
            </div>

            ${renderScanProgressPanel()}
          </div>

          ${run ? `
            <div class="stats-grid">
              ${statCard("Files", run.stats.totalFiles)}
              ${statCard("Duplicate clusters", run.stats.duplicateClusters)}
              ${statCard("Similar clusters", run.stats.similarClusters)}
              ${statCard("Reclaimable", formatBytes(run.stats.reclaimableBytes))}
            </div>
          ` : ""}

          <div class="toolbar">
            ${run ? `
              <div class="selection-actions">
                <button class="ghost-button" data-action="clear-current-run" ${state.scanBusy || !state.serverAvailable ? "disabled" : ""}>Clear current scan results</button>
              </div>
            ` : ""}
            ${state.notice ? `<div class="notice ${state.notice.kind}">${escapeHtml(state.notice.message)}</div>` : ""}
            ${!state.serverAvailable ? `<div class="notice error">Viewer server is offline. Restart it with <code>swift run duplicate-me serve --port ${escapeHtml(window.location.port || "64379")}</code> and refresh this tab.</div>` : ""}
          </div>
        </div>
      </aside>

      <main class="detail">
        ${run ? renderRunDetail(clusters, fileMap, selectedFiles, selectedBytes) : renderOnboardingDetail()}
      </main>
    </div>
  `;

  bindEvents();
  restoreScrollState(scrollState);
}

function renderRunDetail(clusters, fileMap, selectedFiles, selectedBytes) {
  const run = currentRun();
  const hasDuplicateClusters = Boolean(run?.duplicateClusters?.length);
  const hasSimilarClusters = Boolean(run?.similarClusters?.length);
  const emptyMessage = state.search.trim()
    ? "No clusters match the current search or filter."
    : "No clusters are available yet. Start a scan or enable more similarity modes.";

  return `
    <div class="review-toolbar">
      <div class="detail-header review-header">
        <div>
          <div class="eyebrow">Review canvas</div>
          <h2>${clusters.length ? `${clusters.length} cluster${clusters.length === 1 ? "" : "s"} ready` : "No visible clusters"}</h2>
          <div class="subtitle">Scroll one continuous list of duplicate and similar-file groups. Global cleanup actions stay pinned above the results.</div>
        </div>
        <div class="review-header-controls">
          <div class="segmented">
            ${filterButton("all", "All")}
            ${filterButton("duplicates", "Duplicates")}
            ${filterButton("similar", "Similars")}
          </div>
          <input class="search-input review-search" id="cluster-search" type="search" placeholder="Search by path or cluster id" value="${escapeAttr(state.search)}">
        </div>
      </div>

      ${renderScanProgressPanel("wide")}

      <div class="selection-bar">
        <div class="selection-top">
          <div class="selection-summary">
            <div class="eyebrow">Pending cleanup</div>
            <strong>${selectedFiles.length} file${selectedFiles.length === 1 ? "" : "s"} selected</strong>
            <div class="detail-meta">${formatBytes(selectedBytes)} selected for trash</div>
          </div>
          <div class="selection-actions">
            <button class="ghost-button" data-action="expand-all-clusters" ${!clusters.length ? "disabled" : ""}>Expand all</button>
            <button class="ghost-button" data-action="collapse-all-clusters" ${!clusters.length ? "disabled" : ""}>Collapse all</button>
            <button class="ghost-button" data-action="clear-visible-selection" ${state.scanBusy || !state.serverAvailable ? "disabled" : ""}>Clear visible</button>
          </div>
        </div>

        <div class="selection-groups">
          ${hasSimilarClusters ? `
            <div class="selection-group">
              <div class="detail-meta">All similar files</div>
              <div class="selection-actions">
                ${renderAutoModeButtons("global", { clusterType: "similar" })}
              </div>
            </div>
          ` : ""}
          ${hasDuplicateClusters ? `
            <div class="selection-group">
              <div class="detail-meta">All exact duplicates</div>
              <div class="selection-actions">
                ${renderAutoModeButtons("global", { clusterType: "duplicate" })}
              </div>
            </div>
          ` : ""}
        </div>
      </div>
    </div>

    <div class="detail-body">
      ${clusters.length
        ? `<div class="cluster-stream">${clusters.map((cluster) => renderClusterSection(cluster, fileMap)).join("")}</div>`
        : `<div class="empty-state"><h2>No clusters</h2><p>${escapeHtml(emptyMessage)}</p></div>`}
    </div>

    <div class="cleanup-dock">
      <div class="cleanup-dock-copy">
        <div class="eyebrow">Ready to remove</div>
        <strong>${selectedFiles.length} file${selectedFiles.length === 1 ? "" : "s"} selected</strong>
        <div class="detail-meta">${formatBytes(selectedBytes)} will move to Trash after validation.</div>
      </div>
      <div class="selection-actions">
        <button class="ghost-button" data-action="clear-selection" ${state.scanBusy || !state.serverAvailable ? "disabled" : ""}>Clear selection</button>
        <button class="action-button" data-action="trash-selected" ${selectedFiles.length && !state.scanBusy && state.serverAvailable ? "" : "disabled"}>Move selected to Trash</button>
      </div>
    </div>
  `;
}

function renderOnboardingDetail() {
  const progressMarkup = state.scanBusy ? renderScanProgressPanel("wide") : "";
  return `
    <div class="detail-header">
      <div>
        <div class="eyebrow">Start here</div>
        <h2>Choose folders and run a scan</h2>
        <div class="subtitle">${state.scanBusy
          ? "The scan is running now. Progress updates are shown below and results will appear here as soon as it finishes."
          : "The native folder picker opens from the browser UI. Results will appear here as soon as the scan completes."}</div>
      </div>
    </div>
    <div class="detail-body">
      ${progressMarkup}
      <section class="member-card">
        <div class="member-content onboarding-panel">
          <h3>What this phase supports</h3>
          <div class="cluster-pills">
            <span class="cluster-pill">Exact duplicates</span>
            <span class="cluster-pill">Similar images</span>
            <span class="cluster-pill">Similar videos</span>
            <span class="cluster-pill">Audio fingerprints</span>
          </div>
          <p class="member-path">Pick one or more folders, optionally enable similarity modes, then start the scan. The browser session talks only to a localhost server running on this Mac.</p>
        </div>
      </section>
    </div>
  `;
}

function renderClusterSection(cluster, fileMap) {
  const files = cluster.memberIDs.map((id) => fileMap.get(id)).filter(Boolean);
  const selectedCount = files.filter((file) => state.selectedIds.has(file.id)).length;
  const title = clusterTitle(cluster, files);
  const subline = cluster.type === "duplicate"
    ? `${files.length} files · ${formatBytes(cluster.reclaimableBytes)} reclaimable`
    : `${files.length} files · score ${cluster.similarityScore.toFixed(3)}`;
  const collapsed = isClusterCollapsed(cluster.id);

  return `
    <section class="cluster-section ${collapsed ? "collapsed" : ""} ${selectedCount ? "has-selection" : ""}" id="cluster-${cluster.id}">
      <div class="cluster-section-header">
        <div class="cluster-section-copy">
          <div class="cluster-kicker"><span class="dot"></span>${escapeHtml(cluster.type === "duplicate" ? "Exact duplicate group" : `${cluster.mediaKind} similar group`)}</div>
          <h3 title="${escapeAttr(title)}">${escapeHtml(title)}</h3>
          <div class="cluster-meta">${escapeHtml(subline)}</div>
          <div class="cluster-meta">${selectedCount} selected · ${escapeHtml(shortClusterID(cluster.id))}</div>
        </div>
        <div class="cluster-section-actions">
          ${cluster.type === "similar"
            ? `<button class="ghost-button" data-action="dismiss-cluster" data-cluster-id="${cluster.id}" ${state.scanBusy || !state.serverAvailable ? "disabled" : ""}>Hide group</button>`
            : ""}
          <button class="ghost-button" data-action="toggle-cluster-collapse" data-cluster-id="${cluster.id}">${collapsed ? "Expand" : "Collapse"}</button>
          <button class="ghost-button" data-action="cluster-reset" data-cluster-id="${cluster.id}" ${state.scanBusy || !state.serverAvailable ? "disabled" : ""}>${cluster.type === "duplicate" ? "Reset picks" : "Clear picks"}</button>
          ${renderAutoModeButtons("cluster", { clusterId: cluster.id, clusterType: cluster.type })}
        </div>
      </div>
      ${collapsed ? "" : `
        <div class="cluster-members">
          ${files.map((file) => renderMemberCard(cluster, file)).join("")}
        </div>
      `}
    </section>
  `;
}

function renderMemberCard(cluster, file) {
  if (!file) return "";
  const selected = state.selectedIds.has(file.id);
  const isRecommendedKeep = cluster.type === "duplicate" && cluster.recommendedKeepID === file.id;
  if (file.mediaKind === "audio") {
    return `
      <article class="member-card audio-member-card">
        <div class="member-content audio-member-content">
          <div class="member-title">
            <div>
              <div class="eyebrow compact">Audio compare</div>
              <h3>${escapeHtml(lastPathComponent(file.path))}</h3>
              <div class="member-path" title="${escapeAttr(file.path)}">${escapeHtml(file.path)}</div>
            </div>
            <label class="file-toggle">
              <input type="checkbox" data-action="toggle-file" data-cluster-id="${cluster.id}" data-file-id="${file.id}" ${selected ? "checked" : ""} ${state.scanBusy || !state.serverAvailable ? "disabled" : ""}>
              Mark for Trash
            </label>
          </div>
          <div class="cluster-pills">
            <span class="cluster-pill">${escapeHtml(file.mediaKind)}</span>
            <span class="cluster-pill">${formatBytes(file.size)}</span>
            <span class="cluster-pill">${escapeHtml(file.sourceLocationKind)}</span>
            ${isRecommendedKeep ? `<span class="cluster-pill keep">Recommended keep</span>` : ""}
            ${cluster.type === "duplicate" && selected && duplicateLeavesNothing(cluster) ? `<span class="cluster-pill warning">Keep at least one file</span>` : ""}
          </div>
          <div class="detail-meta">Created ${formatDate(file.createdAt)} · Modified ${formatDate(file.modifiedAt)}</div>
          <div class="detail-actions">
            <button class="file-action" data-action="reveal-file" data-file-id="${file.id}" ${state.serverAvailable ? "" : "disabled"}>Reveal in Finder</button>
            ${cluster.type === "similar"
              ? `<button class="file-action" data-action="dismiss-file" data-file-id="${file.id}" ${state.scanBusy || !state.serverAvailable ? "disabled" : ""}>Ignore in similars</button>`
              : ""}
          </div>
        </div>
      </article>
    `;
  }

  return `
    <article class="member-card">
      <div class="member-shell">
        <div class="preview-wrap">${renderPreview(file)}</div>
        <div class="member-content">
          <div class="member-title">
            <div>
              <h3>${escapeHtml(lastPathComponent(file.path))}</h3>
              <div class="member-path" title="${escapeAttr(file.path)}">${escapeHtml(file.path)}</div>
            </div>
            <label class="file-toggle">
              <input type="checkbox" data-action="toggle-file" data-cluster-id="${cluster.id}" data-file-id="${file.id}" ${selected ? "checked" : ""} ${state.scanBusy || !state.serverAvailable ? "disabled" : ""}>
              Mark for Trash
            </label>
          </div>
          <div class="cluster-pills">
            <span class="cluster-pill">${escapeHtml(file.mediaKind)}</span>
            <span class="cluster-pill">${formatBytes(file.size)}</span>
            <span class="cluster-pill">${escapeHtml(file.sourceLocationKind)}</span>
            ${isRecommendedKeep ? `<span class="cluster-pill keep">Recommended keep</span>` : ""}
            ${cluster.type === "duplicate" && selected && duplicateLeavesNothing(cluster) ? `<span class="cluster-pill warning">Keep at least one file</span>` : ""}
          </div>
          <div class="detail-meta">Created ${formatDate(file.createdAt)} · Modified ${formatDate(file.modifiedAt)}</div>
          <div class="detail-actions">
            <button class="file-action" data-action="reveal-file" data-file-id="${file.id}" ${state.serverAvailable ? "" : "disabled"}>Reveal in Finder</button>
            ${cluster.type === "similar"
              ? `<button class="file-action" data-action="dismiss-file" data-file-id="${file.id}" ${state.scanBusy || !state.serverAvailable ? "disabled" : ""}>Ignore in similars</button>`
              : ""}
          </div>
        </div>
      </div>
    </article>
  `;
}

function renderPreview(file) {
  const safePreviewURL = `/preview/${encodeURIComponent(file.id)}`;
  const thumbnailURL = `/thumbnail/${encodeURIComponent(file.id)}`;

  if (file.mediaKind === "image") {
    return `<img loading="lazy" src="${safePreviewURL}" alt="Preview for ${escapeAttr(lastPathComponent(file.path))}">`;
  }
  if (file.mediaKind === "video") {
    return `<img loading="lazy" src="${thumbnailURL}" alt="Video thumbnail for ${escapeAttr(lastPathComponent(file.path))}">`;
  }
  if (file.mediaKind === "audio" && file.size <= 32 * 1024 * 1024) {
    return `
      <div class="audio-preview-card">
        <div class="audio-preview-hero" aria-hidden="true">
          <div class="audio-preview-badge">Audio</div>
          <strong>${escapeHtml(lastPathComponent(file.path).slice(0, 1).toUpperCase())}</strong>
        </div>
        <div class="audio-preview-copy">
          <strong>Inline compare</strong>
          <p>Playback stays local. Use the player below to compare mixes, masters, and duplicate encodes.</p>
        </div>
        <audio class="audio-player" controls preload="metadata" src="${safePreviewURL}"></audio>
      </div>
    `;
  }
  return `<div class="preview-fallback"><strong>${escapeHtml(file.mediaKind.toUpperCase())}</strong><p>Preview is limited for this file type or size. Use Finder reveal for a full inspection.</p></div>`;
}

function bindEvents() {
  document.querySelector("#cluster-search")?.addEventListener("input", (event) => {
    state.search = event.currentTarget.value;
    render();
  });

  document.querySelectorAll(".segmented button").forEach((button) => {
    button.addEventListener("click", () => {
      state.activeFilter = button.dataset.filter;
      render();
    });
  });

  document.querySelectorAll("[data-action='toggle-file']").forEach((input) => {
    input.addEventListener("change", () => {
      const { clusterId, fileId } = input.dataset;
      toggleSelection(clusterId, fileId, input.checked);
      render();
    });
  });

  document.querySelectorAll("[data-action='cluster-reset']").forEach((button) => {
    button.addEventListener("click", () => {
      clearClusterSelection(button.dataset.clusterId);
      render();
    });
  });

  document.querySelectorAll("[data-action='toggle-cluster-collapse']").forEach((button) => {
    button.addEventListener("click", () => {
      toggleClusterCollapsed(button.dataset.clusterId);
      render();
    });
  });

  document.querySelectorAll("[data-action='dismiss-cluster']").forEach((button) => {
    button.addEventListener("click", async () => {
      const cluster = clusterById(button.dataset.clusterId);
      if (!cluster) return;

      for (const memberID of cluster.memberIDs) {
        state.selectedIds.delete(memberID);
      }

      try {
        await apiFetchJSON("/api/dismiss-cluster", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Viewer-Token": config.reviewToken,
          },
          body: JSON.stringify({ clusterID: cluster.id }),
        });
        state.notice = { kind: "success", message: "Hidden this false-positive group from current and future reviews." };
        await loadSession({ resetSelection: false });
      } catch (error) {
        state.notice = { kind: "error", message: error.message };
      } finally {
        render();
      }
    });
  });

  document.querySelector("[data-action='expand-all-clusters']")?.addEventListener("click", () => {
    setVisibleClustersCollapsed(false);
    render();
  });

  document.querySelector("[data-action='collapse-all-clusters']")?.addEventListener("click", () => {
    setVisibleClustersCollapsed(true);
    render();
  });

  document.querySelectorAll("[data-action='apply-auto-mode']").forEach((button) => {
    button.addEventListener("click", () => {
      applySelectionMode(button.dataset.mode, {
        clusterId: button.dataset.clusterId || null,
        clusterType: button.dataset.clusterType || null,
      });
      render();
    });
  });

  document.querySelectorAll("[data-action='reveal-file']").forEach((button) => {
    button.addEventListener("click", async () => {
      try {
        await apiFetch("/api/reveal", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Viewer-Token": config.reviewToken,
          },
          body: JSON.stringify({ fileID: button.dataset.fileId }),
        });
      } catch (error) {
        state.notice = { kind: "error", message: error.message };
        render();
      }
    });
  });

  document.querySelectorAll("[data-action='dismiss-file']").forEach((button) => {
    button.addEventListener("click", async () => {
      const fileID = button.dataset.fileId;
      state.selectedIds.delete(fileID);

      try {
        await apiFetchJSON("/api/dismiss-file", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Viewer-Token": config.reviewToken,
          },
          body: JSON.stringify({ fileID }),
        });
        state.notice = { kind: "success", message: "This file will be excluded from future similar-file scans." };
        await loadSession({ resetSelection: false });
      } catch (error) {
        state.notice = { kind: "error", message: error.message };
      } finally {
        render();
      }
    });
  });

  document.querySelector("[data-action='clear-selection']")?.addEventListener("click", () => {
    state.selectedIds.clear();
    render();
  });

  document.querySelector("[data-action='clear-current-run']")?.addEventListener("click", async () => {
    try {
      await apiFetch("/api/clear-run", {
        method: "POST",
        headers: {
          "X-Viewer-Token": config.reviewToken,
        },
      });
      state.selectedIds.clear();
      state.collapsedClusterIds.clear();
      state.notice = { kind: "success", message: "Current scan results were cleared from the review session." };
      await loadSession({ resetSelection: true });
    } catch (error) {
      state.notice = { kind: "error", message: error.message };
    } finally {
      render();
    }
  });

  document.querySelector("[data-action='clear-visible-selection']")?.addEventListener("click", () => {
    for (const cluster of visibleClusters()) {
      for (const memberID of cluster.memberIDs) {
        state.selectedIds.delete(memberID);
      }
    }
    render();
  });

  document.querySelector("[data-action='trash-selected']")?.addEventListener("click", async () => {
    if (!state.selectedIds.size) return;
    const validationError = validateDuplicateSelection();
    if (validationError) {
      state.notice = { kind: "error", message: validationError };
      render();
      return;
    }

    const clusterIDs = duplicateClusterIDsForSelection();
    const memberIDs = [...state.selectedIds];
    try {
      const payload = await apiFetchJSON("/api/trash", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Viewer-Token": config.reviewToken,
        },
        body: JSON.stringify({ clusterIDs, memberIDs }),
      });

      state.notice = { kind: "success", message: `Moved ${payload.trashedIDs.length} file(s) to Trash. Skipped ${payload.skippedChangedIDs.length}, failed ${payload.failedIDs.length}.` };
      await loadSession({ resetSelection: true });
      render();
    } catch (error) {
      state.notice = { kind: "error", message: error.message };
      render();
    }
  });

  document.querySelector("[data-action='pick-folders']")?.addEventListener("click", async () => {
    state.pickBusy = true;
    state.notice = null;
    render();
    try {
      const payload = await apiFetchJSON("/api/pick-folders", {
        method: "POST",
        headers: {
          "X-Viewer-Token": config.reviewToken,
        },
      });
      state.chosenLocations = payload.locations ?? [];
      if (!state.chosenLocations.length) {
        state.notice = { kind: "error", message: "No folders were selected." };
      }
    } catch (error) {
      state.notice = { kind: "error", message: error.message };
    } finally {
      state.pickBusy = false;
      render();
    }
  });

  document.querySelector("[data-action='reuse-run-locations']")?.addEventListener("click", () => {
    const run = currentRun();
    if (!run) return;
    state.chosenLocations = run.locations.map((location) => location.path);
    render();
  });

  document.querySelector("[data-action='start-scan']")?.addEventListener("click", async () => {
    if (!state.chosenLocations.length || state.scanBusy) return;
    state.scanBusy = true;
    state.notice = { kind: "success", message: "Scan started. Live progress updates will appear below." };
    render();

    try {
      const payload = await apiFetchJSON("/api/scan", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Viewer-Token": config.reviewToken,
        },
        body: JSON.stringify({
          locations: state.chosenLocations,
          options: state.scanOptions,
        }),
      });
      applySession(payload, { resetSelection: false });
      syncScanPolling();
    } catch (error) {
      state.notice = { kind: "error", message: error.message };
      await loadSession({ resetSelection: false }).catch(() => {});
    } finally {
      render();
    }
  });

  document.querySelectorAll("[data-option]").forEach((input) => {
    input.addEventListener("change", () => {
      state.scanOptions[input.dataset.option] = input.checked;
    });
  });
}

function toggleSelection(clusterId, fileId, checked) {
  if (checked) {
    state.selectedIds.add(fileId);
  } else {
    state.selectedIds.delete(fileId);
  }

  const cluster = visibleClusters().find((entry) => entry.id === clusterId);
  if (cluster?.type === "duplicate" && duplicateLeavesNothing(cluster)) {
    state.notice = { kind: "error", message: "A duplicate cluster must keep at least one file." };
  } else {
    state.notice = null;
  }
}

function clearClusterSelection(clusterId) {
  const cluster = visibleClusters().find((entry) => entry.id === clusterId);
  if (!cluster) return;
  for (const id of cluster.memberIDs) {
    state.selectedIds.delete(id);
  }
  state.notice = null;
}

function buildSelectionForRun(run, mode) {
  const next = new Set();
  const fileMap = new Map((run.files ?? []).map((file) => [file.id, file]));
  for (const cluster of run.duplicateClusters ?? []) {
    for (const id of autoSelectedIDsForCluster(cluster, mode, fileMap)) {
      next.add(id);
    }
  }
  return next;
}

function autoSelectedIDsForCluster(cluster, mode, fileMap = fileMapById()) {
  const clusterType = cluster.type ?? "duplicate";
  if (clusterType === "duplicate" && mode === "smart") {
    return [...cluster.autoSelectedIDs];
  }

  const members = cluster.memberIDs
    .map((id) => fileMap.get(id))
    .filter(Boolean);
  if (members.length <= 1) {
    return [];
  }

  const keep = preferredKeepForCluster(cluster, mode, members);
  return members
    .filter((file) => file.id !== keep.id)
    .map((file) => file.id);
}

function preferredKeepForCluster(cluster, mode, members) {
  const clusterType = cluster.type ?? "duplicate";
  if (clusterType === "duplicate" && mode === "smart") {
    const recommended = members.find((file) => file.id === cluster.recommendedKeepID);
    if (recommended) return recommended;
  }

  const sorted = [...members].sort(mode === "smart" ? compareBySmartKeep : compareByModifiedDate);
  return mode === "older" ? sorted[sorted.length - 1] : sorted[0];
}

function compareByModifiedDate(left, right) {
  const modifiedDelta = new Date(left.modifiedAt).getTime() - new Date(right.modifiedAt).getTime();
  if (modifiedDelta !== 0) return modifiedDelta;

  const createdDelta = new Date(left.createdAt).getTime() - new Date(right.createdAt).getTime();
  if (createdDelta !== 0) return createdDelta;

  return left.path.localeCompare(right.path);
}

function compareBySmartKeep(left, right) {
  const locationDelta = smartLocationRank(right) - smartLocationRank(left);
  if (locationDelta !== 0) return locationDelta;

  const createdDelta = new Date(left.createdAt).getTime() - new Date(right.createdAt).getTime();
  if (createdDelta !== 0) return createdDelta;

  const modifiedDelta = new Date(left.modifiedAt).getTime() - new Date(right.modifiedAt).getTime();
  if (modifiedDelta !== 0) return modifiedDelta;

  const pathLengthDelta = left.path.length - right.path.length;
  if (pathLengthDelta !== 0) return pathLengthDelta;

  return left.path.localeCompare(right.path);
}

function smartLocationRank(file) {
  const path = file.path.toLowerCase();
  let rank = file.sourceLocationKind === "preset" ? 4 : 3;
  if (path.includes("/music/") || path.includes("/pictures/") || path.includes("/documents/")) rank += 3;
  if (path.includes("/desktop/")) rank -= 1;
  if (path.includes("/downloads/")) rank -= 2;
  return rank;
}

function applySelectionMode(mode, { clusterId = null, clusterType = null } = {}) {
  const run = currentRun();
  if (!run) return;

  const duplicateClusters = (run.duplicateClusters ?? []).map((cluster) => ({ ...cluster, type: "duplicate" }));
  const similarClusters = (run.similarClusters ?? []).map((cluster) => ({ ...cluster, type: "similar" }));
  const targetClusters = [...duplicateClusters, ...similarClusters].filter((cluster) => {
    if (clusterId && cluster.id !== clusterId) return false;
    if (clusterType && cluster.type !== clusterType) return false;
    return true;
  });
  if (!targetClusters.length) return;

  const fileMap = fileMapById();
  for (const cluster of targetClusters) {
    for (const memberID of cluster.memberIDs) {
      state.selectedIds.delete(memberID);
    }
    for (const memberID of autoSelectedIDsForCluster(cluster, mode, fileMap)) {
      state.selectedIds.add(memberID);
    }
  }

  if ((clusterType ?? targetClusters[0]?.type) === "similar") {
    state.similarAutoSelectMode = mode;
  } else {
    state.autoSelectMode = mode;
  }

  const typeLabel = clusterType === "similar" ? "similar clusters" : clusterType === "duplicate" ? "duplicate clusters" : "the current cluster";
  state.notice = {
    kind: "success",
    message: clusterId
      ? `${autoModeLabel(mode)} applied to the current ${clusterType === "similar" ? "similar cluster" : clusterType === "duplicate" ? "duplicate cluster" : "cluster"}.`
      : `${autoModeLabel(mode)} applied to ${typeLabel}.`,
  };
}

function duplicateLeavesNothing(cluster) {
  if (cluster.type !== "duplicate") return false;
  return cluster.memberIDs.every((id) => state.selectedIds.has(id));
}

function duplicateClusterIDsForSelection() {
  const run = currentRun();
  if (!run) return [];
  return run.duplicateClusters
    .filter((cluster) => cluster.memberIDs.some((id) => state.selectedIds.has(id)))
    .map((cluster) => cluster.id);
}

function validateDuplicateSelection() {
  const run = currentRun();
  if (!run) return "No active run loaded.";
  for (const cluster of run.duplicateClusters) {
    if (cluster.memberIDs.some((id) => state.selectedIds.has(id)) && cluster.memberIDs.every((id) => state.selectedIds.has(id))) {
      return `Cluster ${cluster.id} has every file selected. Leave at least one file unselected.`;
    }
  }
  return null;
}

function renderScanProgressPanel(mode = "compact") {
  const progress = state.session?.scanProgress;
  const activeScanRunID = state.session?.activeScanRunID;
  const progressClass = mode === "wide" ? "scan-progress wide" : "scan-progress";

  if (!state.scanBusy && !progress && !state.session?.scanErrorMessage) {
    return "";
  }

  if (!state.scanBusy && state.session?.scanErrorMessage) {
    return `
      <section class="${progressClass}">
        <div class="scan-progress-header">
          <div>
            <div class="eyebrow">Latest scan</div>
            <strong>Scan failed</strong>
          </div>
        </div>
        <p class="scan-progress-copy">${escapeHtml(state.session.scanErrorMessage)}</p>
      </section>
    `;
  }

  const stage = progress?.stage ? humanizeStage(progress.stage) : "Preparing";
  const filesSeen = progress?.filesSeen ?? 0;
  const bytesSeen = progress?.bytesSeen ?? 0;
  const candidatesFound = progress?.candidatesFound ?? 0;

  return `
    <section class="${progressClass}">
      <div class="scan-progress-header">
        <div>
          <div class="eyebrow">Scan progress</div>
          <strong>${escapeHtml(stage)}</strong>
        </div>
        ${activeScanRunID ? `<span class="cluster-pill">${escapeHtml(shortRunID(activeScanRunID))}</span>` : ""}
      </div>
      <div class="scan-progress-copy">Scanning selected folders locally. Results stay on this Mac and will replace the current review as soon as the run completes.</div>
      <div class="progress-metrics">
        ${progressMetric("Files seen", filesSeen)}
        ${progressMetric("Bytes seen", formatBytes(bytesSeen))}
        ${progressMetric("Candidates", candidatesFound)}
      </div>
    </section>
  `;
}

function renderAutoModeButtons(scope, { clusterId = "", clusterType = "duplicate" } = {}) {
  const activeMode = clusterType === "similar" ? state.similarAutoSelectMode : state.autoSelectMode;
  return [
    { mode: "smart", label: "Smart" },
    { mode: "newer", label: "Mark newer" },
    { mode: "older", label: "Mark older" },
  ].map(({ mode, label }) => `
    <button
      class="ghost-button ${activeMode === mode ? "active-mode" : ""}"
      data-action="apply-auto-mode"
      data-mode="${mode}"
      data-cluster-type="${clusterType}"
      ${clusterId ? `data-cluster-id="${clusterId}"` : ""}
      ${state.scanBusy || !state.serverAvailable ? "disabled" : ""}
    >${scope === "cluster" ? label : label}</button>
  `).join("");
}

function autoModeLabel(mode) {
  switch (mode) {
    case "newer":
      return "Mark newer";
    case "older":
      return "Mark older";
    default:
      return "Smart select";
  }
}

function progressMetric(label, value) {
  return `<div class="progress-metric"><span>${escapeHtml(label)}</span><strong>${escapeHtml(String(value))}</strong></div>`;
}

function humanizeStage(stage) {
  switch (stage) {
    case "enumerating":
      return "Enumerating files";
    case "hashing":
      return "Hashing duplicate candidates";
    case "fingerprinting":
      return "Fingerprinting media";
    case "clustering":
      return "Building clusters";
    case "finished":
      return "Finished";
    case "failed":
      return "Failed";
    default:
      return "Preparing scan";
  }
}

function shortRunID(runID) {
  return runID.slice(0, 8);
}

function shortClusterID(clusterID) {
  return clusterID.slice(0, 12);
}

function clusterTitle(cluster, files) {
  const primary = files[0] ? lastPathComponent(files[0].path) : cluster.id;
  if (files.length <= 1) return primary;
  return `${primary} +${files.length - 1}`;
}

function clusterById(clusterID) {
  const run = currentRun();
  if (!run) return null;
  const duplicate = run.duplicateClusters.find((cluster) => cluster.id === clusterID);
  if (duplicate) return { ...duplicate, type: "duplicate" };
  const similar = run.similarClusters.find((cluster) => cluster.id === clusterID);
  if (similar) return { ...similar, type: "similar" };
  return null;
}

function isClusterCollapsed(clusterId) {
  return state.collapsedClusterIds.has(clusterId);
}

function toggleClusterCollapsed(clusterId) {
  if (state.collapsedClusterIds.has(clusterId)) {
    state.collapsedClusterIds.delete(clusterId);
  } else {
    state.collapsedClusterIds.add(clusterId);
  }
}

function setVisibleClustersCollapsed(collapsed) {
  for (const cluster of visibleClusters()) {
    if (collapsed) {
      state.collapsedClusterIds.add(cluster.id);
    } else {
      state.collapsedClusterIds.delete(cluster.id);
    }
  }
}

function captureScrollState() {
  return {
    sidebarTop: document.querySelector(".sidebar")?.scrollTop ?? 0,
    detailTop: document.querySelector(".detail-body")?.scrollTop ?? 0,
  };
}

function restoreScrollState(scrollState) {
  const sidebar = document.querySelector(".sidebar");
  const detailBody = document.querySelector(".detail-body");
  if (sidebar) {
    sidebar.scrollTop = scrollState.sidebarTop;
  }
  if (detailBody) {
    detailBody.scrollTop = scrollState.detailTop;
  }
}

function syncScanPolling() {
  const shouldPoll = Boolean(state.session?.isScanning);
  if (!shouldPoll) {
    if (scanPollHandle !== null) {
      clearTimeout(scanPollHandle);
      scanPollHandle = null;
    }
    return;
  }

  if (scanPollHandle !== null) {
    return;
  }

  scanPollHandle = setTimeout(async () => {
    scanPollHandle = null;
    try {
      await loadSession({ resetSelection: false });
    } catch (error) {
      state.notice = { kind: "error", message: error.message };
      state.scanBusy = false;
      state.serverAvailable = false;
    } finally {
      render();
      syncScanPolling();
    }
  }, 1000);
}

function optionToggle(key, label) {
  return `
    <label class="option-toggle">
      <input type="checkbox" data-option="${key}" ${state.scanOptions[key] ? "checked" : ""} ${state.scanBusy ? "disabled" : ""}>
      <span>${escapeHtml(label)}</span>
    </label>
  `;
}

function filterButton(filter, label) {
  const active = state.activeFilter === filter ? "active" : "";
  return `<button class="${active}" data-filter="${filter}" ${currentRun() ? "" : "disabled"}>${label}</button>`;
}

function statCard(label, value) {
  return `<div class="stat-card"><span>${escapeHtml(label)}</span><strong>${escapeHtml(String(value))}</strong></div>`;
}

function formatBytes(bytes) {
  if (bytes < 1000) return `${bytes} B`;
  if (bytes < 1000 * 1000) return `${(bytes / 1000).toFixed(bytes >= 10000 ? 0 : 1)} KB`;
  if (bytes < 1000 * 1000 * 1000) return `${(bytes / (1000 * 1000)).toFixed(bytes >= 1000 * 1000 * 10 ? 0 : 1)} MB`;
  return `${(bytes / (1000 * 1000 * 1000)).toFixed(1)} GB`;
}

function formatDate(dateString) {
  const date = new Date(dateString);
  return new Intl.DateTimeFormat(undefined, {
    year: "numeric",
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

function lastPathComponent(path) {
  return path.split("/").filter(Boolean).pop() || path;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;");
}

function escapeAttr(value) {
  return escapeHtml(value).replaceAll("'", "&#39;");
}
