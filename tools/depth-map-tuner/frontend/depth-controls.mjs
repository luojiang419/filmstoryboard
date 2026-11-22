export const CONTROL_RANGES = Object.freeze({
  farPoint: Object.freeze({ min: 0, max: 99, step: 1, label: "远景黑点", unit: "%", nodeRange: "节点 0–95" }),
  nearPoint: Object.freeze({ min: 1, max: 100, step: 1, label: "近景白点", unit: "%", nodeRange: "节点 5–100" }),
  midtone: Object.freeze({ min: -100, max: 100, step: 1, label: "中间层次", unit: "", nodeRange: "节点 -50–50" }),
  contrast: Object.freeze({ min: 0, max: 300, step: 1, label: "对比度", unit: "%", nodeRange: "节点 50–150" }),
  brightness: Object.freeze({ min: -100, max: 100, step: 1, label: "亮度", unit: "", nodeRange: "节点 -30–30" }),
  smooth: Object.freeze({ min: 0, max: 50, step: 1, label: "平滑", unit: " 级", nodeRange: "节点 0–10" }),
});

export const DEFAULT_CONTROLS = Object.freeze({
  farPoint: 0,
  nearPoint: 100,
  midtone: 0,
  contrast: 100,
  brightness: 0,
  smooth: 0,
  invert: false,
});

export const CONTROL_PRESETS = Object.freeze({
  neutral: Object.freeze({ label: "原始中性", values: DEFAULT_CONTROLS }),
  portrait: Object.freeze({
    label: "人像层次",
    values: Object.freeze({ farPoint: 4, nearPoint: 96, midtone: 16, contrast: 122, brightness: 0, smooth: 2, invert: false }),
  }),
  soft: Object.freeze({
    label: "柔和平滑",
    values: Object.freeze({ farPoint: 0, nearPoint: 100, midtone: 28, contrast: 82, brightness: 5, smooth: 8, invert: false }),
  }),
  dramatic: Object.freeze({
    label: "强烈纵深",
    values: Object.freeze({ farPoint: 12, nearPoint: 88, midtone: -14, contrast: 185, brightness: -4, smooth: 1, invert: false }),
  }),
  cutout: Object.freeze({
    label: "硬边分层",
    values: Object.freeze({ farPoint: 24, nearPoint: 76, midtone: -22, contrast: 245, brightness: -10, smooth: 0, invert: false }),
  }),
});

const clamp = (value, min, max) => Math.max(min, Math.min(max, Number(value)));

export function normalizeControls(source = {}, changedField = "") {
  const next = {};
  for (const [field, range] of Object.entries(CONTROL_RANGES)) {
    const fallback = DEFAULT_CONTROLS[field];
    const value = Number.isFinite(Number(source[field])) ? Number(source[field]) : fallback;
    const clamped = clamp(value, range.min, range.max);
    next[field] = Math.round(clamped / range.step) * range.step;
  }
  next.invert = Boolean(source.invert);

  if (changedField === "farPoint" && next.farPoint >= next.nearPoint) {
    next.nearPoint = Math.min(CONTROL_RANGES.nearPoint.max, next.farPoint + 1);
  }
  if (changedField === "nearPoint" && next.nearPoint <= next.farPoint) {
    next.farPoint = Math.max(CONTROL_RANGES.farPoint.min, next.nearPoint - 1);
  }
  if (next.nearPoint <= next.farPoint) {
    next.nearPoint = Math.min(CONTROL_RANGES.nearPoint.max, next.farPoint + 1);
  }
  if (next.nearPoint <= next.farPoint) {
    next.farPoint = Math.max(CONTROL_RANGES.farPoint.min, next.nearPoint - 1);
  }
  return next;
}

export function controlSignature(source = {}) {
  const controls = normalizeControls(source);
  return [
    controls.farPoint,
    controls.nearPoint,
    controls.midtone,
    controls.contrast,
    controls.brightness,
    controls.smooth,
    controls.invert ? 1 : 0,
  ].join("|");
}

export function formatErrorMessage(error, fallback = "操作失败") {
  if (typeof error === "string" && error.trim()) return error.trim();
  if (typeof error?.message === "string" && error.message.trim()) return error.message.trim();
  if (typeof error?.error === "string" && error.error.trim()) return error.error.trim();
  const rendered = String(error ?? "").trim();
  return rendered && rendered !== "[object Object]" ? rendered : fallback;
}

export function presetKeyFor(source = {}) {
  const signature = controlSignature(source);
  return Object.entries(CONTROL_PRESETS).find(([, preset]) => controlSignature(preset.values) === signature)?.[0] || "";
}

export function buildDepthLut(source = {}) {
  const controls = normalizeControls(source);
  const lut = new Uint8ClampedArray(256);
  const far = controls.farPoint / 100;
  const near = controls.nearPoint / 100;
  const contrast = controls.contrast / 100;
  const brightness = controls.brightness / 100;
  const gamma = Math.pow(2, -controls.midtone / 50);
  for (let index = 0; index < 256; index += 1) {
    let value = Math.max(0, Math.min(1, (index / 255 - far) / Math.max(0.01, near - far)));
    value = Math.pow(value, gamma);
    value = (value - 0.5) * contrast + 0.5 + brightness;
    value = Math.max(0, Math.min(1, value));
    if (controls.invert) value = 1 - value;
    lut[index] = Math.round(value * 255);
  }
  return lut;
}

export function controlsFromConfig(config) {
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    throw new Error("配置文件必须是 JSON 对象");
  }
  const compatibilityValues = config.compatibility?.values;
  const canvasDefaults = config.canvasDefaults;
  const legacyCanvasValues = config.depthMapControls;
  const plainParameters = config.parameters;
  let source = compatibilityValues && typeof compatibilityValues === "object"
    ? compatibilityValues
    : canvasDefaults && typeof canvasDefaults === "object"
      ? canvasDefaults
      : legacyCanvasValues;
  if (!source || typeof source !== "object") {
    source = {};
    if (plainParameters && typeof plainParameters === "object") {
      for (const field of [...Object.keys(CONTROL_RANGES), "invert"]) {
        const value = plainParameters[field];
        source[field] = value && typeof value === "object" && "value" in value ? value.value : value;
      }
    }
  }
  const recognized = [...Object.keys(CONTROL_RANGES), "invert"].some((field) => source?.[field] !== undefined);
  if (!recognized) throw new Error("配置中没有可识别的深度图参数");
  return normalizeControls({ ...DEFAULT_CONTROLS, ...source });
}

export function buildParameterConfig({ controls, component = {}, input = {}, dimensions = {} } = {}) {
  const normalized = normalizeControls(controls);
  const parameters = {};
  for (const [field, range] of Object.entries(CONTROL_RANGES)) {
    parameters[field] = {
      label: range.label,
      value: normalized[field],
      min: range.min,
      max: range.max,
      step: range.step,
      unit: range.unit,
    };
  }
  parameters.invert = { label: "反转深度", value: normalized.invert, type: "boolean" };
  return {
    schema: "shiyin.depth-map-parameters/v1",
    schemaVersion: 1,
    createdAt: new Date().toISOString(),
    description: "SHIYIN 高精度人物深度图调参器导出配置",
    model: {
      component: "person-depth",
      version: component.version || "",
      sourceLabel: component.sourceLabel || "",
      outputBitDepth: 8,
      licenseNotice: component.licenseNotice || "Depth Anything V2 Large: CC-BY-NC-4.0; BiRefNet: MIT",
    },
    input: {
      name: input.name || "",
      width: Number(dimensions.width) || 0,
      height: Number(dimensions.height) || 0,
    },
    canvasDefaults: normalized,
    parameters,
    compatibility: {
      target: "depthMapControls",
      algorithm: "shiyin-depth-lut-v1",
      values: normalized,
    },
  };
}
