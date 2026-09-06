import {
  buildDepthLut,
  CONTROL_PRESETS,
  CONTROL_RANGES,
  DEFAULT_CONTROLS,
  formatErrorMessage,
  normalizeControls,
  presetKeyFor,
} from "./depth-controls.mjs";

const elements = {
  modelStatus: document.querySelector("[data-model-status]"),
  modelTitle: document.querySelector("[data-model-title]"),
  modelDetail: document.querySelector("[data-model-detail]"),
  inputStage: document.querySelector(".input-stage"),
  inputImage: document.querySelector("[data-input-image]"),
  inputEmpty: document.querySelector("[data-input-empty]"),
  inputName: document.querySelector("[data-input-name]"),
  inputDimensions: document.querySelector("[data-input-dimensions]"),
  outputCanvas: document.querySelector("[data-depth-preview]"),
  outputEmpty: document.querySelector("[data-output-empty]"),
  outputDimensions: document.querySelector("[data-output-dimensions]"),
  processing: document.querySelector("[data-processing]"),
  previewState: document.querySelector("[data-preview-state]"),
  presetStrip: document.querySelector("[data-presets]"),
  statusMessage: document.querySelector("[data-status-message]"),
  toastRegion: document.querySelector("[data-toast-region]"),
  exportDepth: document.querySelector('[data-action="export-depth"]'),
  modeLabel: document.querySelector("[data-mode-label]"),
  processingTitle: document.querySelector("[data-processing-title]"),
};

const state = {
  component: null,
  input: null,
  inputDimensions: { width: 0, height: 0 },
  depth: null,
  depthImage: null,
  controls: loadSavedControls(),
  generation: 0,
  renderFrame: 0,
  busy: false,
  mode: "person",
  configPath: "",
};

function tauriInvoke(command, args = {}) {
  const invoke = window.__TAURI__?.core?.invoke || window.__TAURI_INTERNALS__?.invoke;
  if (!invoke) return Promise.reject(new Error("Tauri 原生接口不可用，请通过桌面调参器启动"));
  return invoke(command, args);
}

function loadSavedControls(mode = "person") {
  try {
    const raw = localStorage.getItem(`filmstoryboard-depth-tuner-${mode}-draft-v1`);
    return normalizeControls(raw ? JSON.parse(raw) : DEFAULT_CONTROLS);
  } catch {
    return normalizeControls(DEFAULT_CONTROLS);
  }
}

function saveControls() {
  try {
    localStorage.setItem(`filmstoryboard-depth-tuner-${state.mode}-draft-v1`, JSON.stringify(state.controls));
  } catch {
    // WebView storage failure should not stop tuning or export.
  }
}

function setStatus(message) {
  elements.statusMessage.textContent = message;
}

function toast(message, type = "") {
  const item = document.createElement("div");
  item.className = `toast ${type}`.trim();
  item.textContent = message;
  elements.toastRegion.appendChild(item);
  window.setTimeout(() => item.remove(), 3600);
}

function formatBytes(bytes) {
  const value = Number(bytes) || 0;
  if (value < 1024) return `${value} B`;
  const units = ["KB", "MB", "GB"];
  let scaled = value;
  let index = -1;
  do {
    scaled /= 1024;
    index += 1;
  } while (scaled >= 1024 && index < units.length - 1);
  return `${scaled.toFixed(scaled >= 10 ? 1 : 2)} ${units[index]}`;
}

function formatValue(field, value) {
  const number = Number(value) || 0;
  if (field === "farPoint" || field === "nearPoint" || field === "contrast") return `${number}%`;
  if (field === "smooth") return number === 0 ? "关闭" : `${number} 级`;
  return `${number > 0 ? "+" : ""}${number}`;
}

function setModelStatus(component) {
  state.component = component;
  const ready = Boolean(component?.ready);
  elements.modelStatus.dataset.modelStatus = ready ? "ready" : "error";
  elements.modelTitle.textContent = ready ? `共享模型已就绪 · ${component.version || "未知版本"}` : "共享模型未就绪";
  elements.modelDetail.textContent = ready
    ? `${component.sourceLabel || "person-depth"} · 未复制模型`
    : component?.message || "请重新定位 person-depth 组件";
  elements.modelDetail.title = ready ? component.componentRoot || "" : component?.message || "";
  setStatus(ready ? "工作台已就绪，选择图片后将调用共享模型一次" : component?.message || "共享模型不可用");
}

async function refreshModelStatus() {
  try {
    setModelStatus(await tauriInvoke("get_component_status"));
  } catch (error) {
    setModelStatus({ ready: false, message: formatErrorMessage(error, "共享模型状态读取失败") });
  }
}

function loadHtmlImage(url) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error("图片解码失败"));
    image.src = url;
  });
}

function renderAdjustedDepth(image, controls, target, maxEdge = 0) {
  const sourceWidth = Math.max(1, Number(image.naturalWidth || image.width) || 1);
  const sourceHeight = Math.max(1, Number(image.naturalHeight || image.height) || 1);
  const scale = maxEdge > 0 ? Math.min(1, maxEdge / Math.max(sourceWidth, sourceHeight)) : 1;
  const width = Math.max(1, Math.round(sourceWidth * scale));
  const height = Math.max(1, Math.round(sourceHeight * scale));
  const work = document.createElement("canvas");
  work.width = width;
  work.height = height;
  const context = work.getContext("2d", { willReadFrequently: true });
  context.drawImage(image, 0, 0, width, height);
  const pixels = context.getImageData(0, 0, width, height);
  const lut = buildDepthLut(controls);
  for (let index = 0; index < pixels.data.length; index += 4) {
    const gray = Math.round((pixels.data[index] + pixels.data[index + 1] + pixels.data[index + 2]) / 3);
    const mapped = lut[gray];
    pixels.data[index] = mapped;
    pixels.data[index + 1] = mapped;
    pixels.data[index + 2] = mapped;
  }
  context.putImageData(pixels, 0, 0);
  target.width = width;
  target.height = height;
  const targetContext = target.getContext("2d");
  targetContext.save();
  targetContext.fillStyle = controls.invert ? "#fff" : "#000";
  targetContext.fillRect(0, 0, width, height);
  if (controls.smooth > 0) {
    const radius = Math.max(0.2, controls.smooth * width / 1000);
    targetContext.filter = `blur(${radius.toFixed(2)}px)`;
  }
  targetContext.drawImage(work, 0, 0);
  targetContext.restore();
  return target;
}

function schedulePreviewRender() {
  if (!state.depthImage) return;
  if (state.renderFrame) cancelAnimationFrame(state.renderFrame);
  state.renderFrame = requestAnimationFrame(() => {
    state.renderFrame = 0;
    try {
      renderAdjustedDepth(state.depthImage, state.controls, elements.outputCanvas, 1400);
      elements.outputCanvas.hidden = false;
      elements.outputEmpty.hidden = true;
      elements.previewState.hidden = false;
      elements.exportDepth.disabled = false;
      setStatus("实时预览已更新；导出时会按原始分辨率重新计算");
    } catch (error) {
      const message = formatErrorMessage(error, "实时预览失败");
      toast(message, "error");
      setStatus(message);
    }
  });
}

function syncControlUi() {
  const activePreset = presetKeyFor(state.controls);
  document.querySelectorAll("[data-field]").forEach((control) => {
    const field = control.dataset.field;
    if (control.type === "checkbox") {
      control.checked = Boolean(state.controls[field]);
      return;
    }
    const range = CONTROL_RANGES[field];
    if (!range) return;
    control.min = range.min;
    control.max = range.max;
    control.step = range.step;
    control.value = state.controls[field];
    const fill = ((state.controls[field] - range.min) / (range.max - range.min)) * 100;
    control.style.setProperty("--fill", `${fill}%`);
    control.closest(".range-control")?.querySelector("output")?.replaceChildren(formatValue(field, state.controls[field]));
  });
  elements.presetStrip.querySelectorAll("[data-preset]").forEach((button) => {
    button.classList.toggle("active", button.dataset.preset === activePreset);
  });
}

function setControls(values, changedField = "") {
  state.controls = normalizeControls({ ...state.controls, ...values }, changedField);
  saveControls();
  syncControlUi();
  schedulePreviewRender();
}

function setBusy(busy) {
  state.busy = busy;
  elements.processing.hidden = !busy;
  elements.inputStage.disabled = busy;
  if (busy) elements.exportDepth.disabled = true;
  else elements.exportDepth.disabled = !state.depthImage;
}

function clearDepth() {
  state.depth = null;
  state.depthImage = null;
  elements.outputCanvas.hidden = true;
  elements.outputEmpty.hidden = false;
  elements.previewState.hidden = true;
  elements.exportDepth.disabled = true;
  elements.outputDimensions.textContent = "8-BIT PNG";
}

async function applyInputPayload(payload) {
  const generation = ++state.generation;
  const inputImage = await loadHtmlImage(payload.dataUrl);
  if (generation !== state.generation) return;
  state.input = payload;
  state.inputDimensions = { width: inputImage.naturalWidth, height: inputImage.naturalHeight };
  elements.inputImage.src = payload.dataUrl;
  elements.inputImage.hidden = false;
  elements.inputEmpty.hidden = true;
  elements.inputName.textContent = payload.name;
  elements.inputName.title = payload.path;
  elements.inputName.hidden = false;
  elements.inputDimensions.textContent = `${inputImage.naturalWidth} × ${inputImage.naturalHeight} · ${formatBytes(payload.size)}`;
  clearDepth();
  setBusy(true);
  setStatus(`正在使用共享模型提取 ${payload.name} 的深度…`);
  try {
    const depth = await tauriInvoke("generate_depth", { inputPath: payload.path, mode: state.mode });
    if (generation !== state.generation) return;
    const depthImage = await loadHtmlImage(depth.dataUrl);
    if (generation !== state.generation) return;
    state.depth = depth;
    state.depthImage = depthImage;
    elements.outputDimensions.textContent = `${depth.width} × ${depth.height} · ${depth.bitDepth}-BIT PNG`;
    schedulePreviewRender();
    toast("深度提取完成，拖动底部参数即可实时调整", "success");
  } catch (error) {
    if (generation !== state.generation) return;
    clearDepth();
    const message = formatErrorMessage(error, "深度提取失败");
    toast(message, "error");
    setStatus(message);
  } finally {
    if (generation === state.generation) setBusy(false);
  }
}

async function chooseImage() {
  if (state.busy) return;
  try {
    const payload = await tauriInvoke("choose_input_image");
    if (payload) await applyInputPayload(payload);
  } catch (error) {
    toast(formatErrorMessage(error, "选择图片失败"), "error");
  }
}

async function loadDroppedPath(path) {
  if (state.busy || !path) return;
  try {
    const payload = await tauriInvoke("load_input_image", { path });
    await applyInputPayload(payload);
  } catch (error) {
    toast(formatErrorMessage(error, "拖入图片失败"), "error");
  }
}

function safeStem(name = "depth-map") {
  const withoutExtension = name.replace(/\.[^.]+$/, "");
  return withoutExtension.replace(/[\\/:*?"<>|\u0000-\u001f]/g, "_").trim() || "depth-map";
}

function timestamp() {
  const date = new Date();
  const pad = (value) => String(value).padStart(2, "0");
  return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
}

async function exportDepth() {
  if (!state.depthImage || state.busy) return;
  elements.exportDepth.disabled = true;
  setStatus("正在按原始分辨率渲染深度图…");
  try {
    const fullCanvas = document.createElement("canvas");
    renderAdjustedDepth(state.depthImage, state.controls, fullCanvas);
    const dataUrl = fullCanvas.toDataURL("image/png");
    const name = `${safeStem(state.input?.name)}-depth-${timestamp()}.png`;
    const path = await tauriInvoke("export_depth_png", { dataUrl, suggestedName: name });
    if (path) {
      toast(`深度图已保存：${path}`, "success");
      setStatus(`深度图已导出到 ${path}`);
    } else {
      setStatus("已取消深度图导出");
    }
  } catch (error) {
    const message = formatErrorMessage(error, "深度图导出失败");
    toast(message, "error");
    setStatus(message);
  } finally {
    elements.exportDepth.disabled = !state.depthImage;
  }
}

async function saveConfig() {
  try {
    const path = await tauriInvoke("save_parameter_config", {
      controls: normalizeControls(state.controls),
    });
    toast(`${elements.modeLabel.textContent}参数已保存并全局生效`, "success");
    setStatus(`配置已保存到 ${path}`);
  } catch (error) {
    toast(formatErrorMessage(error, "参数配置保存失败"), "error");
  }
}

async function locateModel() {
  try {
    const component = await tauriInvoke("choose_component_root");
    if (component) {
      setModelStatus(component);
      toast("共享模型位置已更新，没有复制或安装文件", "success");
    }
  } catch (error) {
    const message = formatErrorMessage(error, "共享模型定位失败");
    toast(message, "error");
    setModelStatus({ ready: false, message });
  }
}

function initializePresets() {
  for (const [key, preset] of Object.entries(CONTROL_PRESETS)) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "preset-button";
    button.dataset.preset = key;
    button.textContent = preset.label;
    button.addEventListener("click", () => setControls(preset.values));
    elements.presetStrip.appendChild(button);
  }
}

function bindControls() {
  document.querySelectorAll("[data-field]").forEach((control) => {
    const field = control.dataset.field;
    control.addEventListener(control.type === "checkbox" ? "change" : "input", () => {
      setControls({ [field]: control.type === "checkbox" ? control.checked : Number(control.value) }, field);
    });
  });
  document.querySelector('[data-action="choose-image"]').addEventListener("click", chooseImage);
  document.querySelector('[data-action="locate-model"]').addEventListener("click", locateModel);
  document.querySelector('[data-action="reset-controls"]').addEventListener("click", () => {
    setControls(DEFAULT_CONTROLS);
    toast("已恢复原始中性参数");
  });
  document.querySelector('[data-action="export-depth"]').addEventListener("click", exportDepth);
  document.querySelector('[data-action="save-config"]').addEventListener("click", saveConfig);
}

async function bindTauriFileDrop() {
  const getCurrentWebview = window.__TAURI__?.webview?.getCurrentWebview;
  if (!getCurrentWebview) return;
  try {
    await getCurrentWebview().onDragDropEvent((event) => {
      const payload = event.payload || {};
      if (payload.type === "over") elements.inputStage.classList.add("is-dragging");
      if (payload.type === "leave") elements.inputStage.classList.remove("is-dragging");
      if (payload.type === "drop") {
        elements.inputStage.classList.remove("is-dragging");
        loadDroppedPath(payload.paths?.[0]);
      }
    });
  } catch {
    // Native picker remains available when WebView drag events are unavailable.
  }
}

async function initialize() {
  initializePresets();
  bindControls();
  try {
    const context = await tauriInvoke("get_launch_context");
    state.mode = context.mode === "professional" ? "professional" : "person";
    state.configPath = context.configPath || "";
    elements.modeLabel.textContent = context.modeLabel
      || (state.mode === "professional" ? "专业模式" : "人物模式");
    elements.processingTitle.textContent = state.mode === "professional"
      ? "正在提取完整场景深度"
      : "正在提取人物深度";
    const controls = await tauriInvoke("load_parameter_config");
    state.controls = normalizeControls(controls || loadSavedControls(state.mode));
  } catch (error) {
    toast(formatErrorMessage(error, "读取启动模式或共享配置失败"), "error");
    state.controls = loadSavedControls(state.mode);
  }
  syncControlUi();
  bindTauriFileDrop();
  await refreshModelStatus();
}

initialize();
