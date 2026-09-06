import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  buildDepthLut,
  buildParameterConfig,
  CONTROL_RANGES,
  controlsFromConfig,
  DEFAULT_CONTROLS,
  formatErrorMessage,
  normalizeControls,
} from "../frontend/depth-controls.mjs";

test("expanded ranges are wider than the infinite-canvas controls", () => {
  assert.deepEqual([CONTROL_RANGES.midtone.min, CONTROL_RANGES.midtone.max], [-100, 100]);
  assert.deepEqual([CONTROL_RANGES.contrast.min, CONTROL_RANGES.contrast.max], [0, 300]);
  assert.deepEqual([CONTROL_RANGES.brightness.min, CONTROL_RANGES.brightness.max], [-100, 100]);
  assert.equal(CONTROL_RANGES.smooth.max, 50);
});

test("normalization clamps values and preserves a one-point depth interval", () => {
  assert.deepEqual(
    normalizeControls({ farPoint: 200, nearPoint: -20, midtone: 900, contrast: -5, brightness: -400, smooth: 999, invert: 1 }),
    { farPoint: 99, nearPoint: 100, midtone: 100, contrast: 0, brightness: -100, smooth: 50, invert: true },
  );
  const movedNear = normalizeControls({ ...DEFAULT_CONTROLS, farPoint: 80, nearPoint: 20 }, "nearPoint");
  assert.deepEqual([movedNear.farPoint, movedNear.nearPoint], [19, 20]);
});

test("neutral LUT is identity and inverted LUT reverses its endpoints", () => {
  const neutral = buildDepthLut(DEFAULT_CONTROLS);
  assert.equal(neutral[0], 0);
  assert.equal(neutral[128], 128);
  assert.equal(neutral[255], 255);
  const inverted = buildDepthLut({ ...DEFAULT_CONTROLS, invert: true });
  assert.equal(inverted[0], 255);
  assert.equal(inverted[255], 0);
});

test("versioned config keeps values, ranges and canvas compatibility mapping", () => {
  const controls = normalizeControls({ ...DEFAULT_CONTROLS, contrast: 183, smooth: 12 });
  const config = buildParameterConfig({
    controls,
    component: { version: "1.0.0-test", sourceLabel: "shared" },
    input: { name: "人物.jpg" },
    dimensions: { width: 4000, height: 6000 },
  });
  assert.equal(config.schema, "shiyin.depth-map-parameters/v1");
  assert.equal(config.parameters.contrast.max, 300);
  assert.equal(config.compatibility.target, "depthMapControls");
  assert.deepEqual(controlsFromConfig(config), controls);
  assert.deepEqual(controlsFromConfig({ depthMapControls: controls }), controls);
});

test("parameter object values can be imported without compatibility metadata", () => {
  const imported = controlsFromConfig({
    parameters: {
      farPoint: { value: 8 },
      nearPoint: { value: 91 },
      contrast: { value: 210 },
      invert: { value: true },
    },
  });
  assert.equal(imported.farPoint, 8);
  assert.equal(imported.nearPoint, 91);
  assert.equal(imported.contrast, 210);
  assert.equal(imported.invert, true);
});

test("Tauri string rejections keep their real diagnostic message", () => {
  assert.equal(formatErrorMessage("worker 找不到中文路径", "深度提取失败"), "worker 找不到中文路径");
  assert.equal(formatErrorMessage(new Error("CUDA out of memory"), "深度提取失败"), "CUDA out of memory");
  assert.equal(formatErrorMessage({}, "深度提取失败"), "深度提取失败");
});

test("plugin UI exposes mode and icon-free global save action", async () => {
  const html = await readFile(new URL("../frontend/index.html", import.meta.url), "utf8");
  assert.match(html, /data-mode-label/);
  assert.match(html, /data-action="save-config"/);
  assert.doesNotMatch(
    html,
    /data-action="save-config"[^>]*>[\s\S]*?<svg[\s\S]*?保存配置/,
  );
  assert.doesNotMatch(html, /data-action="export-config"/);
});
