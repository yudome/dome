const assert = require("assert");
const fs = require("fs");
const path = require("path");

const source = fs.readFileSync(path.join(__dirname, "Toml.js"), "utf8").replace(".pragma library", "");
const Toml = new Function(source + "; return { parse, steps, nearest, move, placed };")();

const config = fs.readFileSync(path.join(__dirname, "..", "..", "config.toml"), "utf8");
const doc = Toml.parse(config);
const find = (key) => doc.sections.flatMap((s) => s.keys).find((k) => k.key === key);

assert.strictEqual(doc.sections[0].name, "colors");
assert.strictEqual(find("surface").type, "color");
assert.strictEqual(find("mono").type, "bool");
assert.strictEqual(find("barCells").type, "int");
assert.strictEqual(find("barThickness").type, "float");
assert.strictEqual(find("barThickness").advanced, false);
assert.strictEqual(find("barSweepMs").advanced, true);
assert.strictEqual(find("barStatMode").type, "enum");
assert.strictEqual(find("iconCpu").type, "glyph");
assert.strictEqual(find("iconCpu").value, "");
assert.strictEqual(find("iconOutput").value, String.fromCodePoint(0xf0379));
assert.strictEqual(find("clockFormat").type, "text");
assert.strictEqual(find("barBorderWidth").comment, "barFloating ? -1 : 0");
assert.strictEqual(find("powerActions"), undefined);
assert.strictEqual(find("lockDigits"), undefined);
assert.strictEqual(find("weatherCodes"), undefined);
assert.strictEqual(find("lockCooldownMs").value, 3000);
assert.strictEqual(find("powerCellSize").value, 96);
assert.strictEqual(doc.sections.find((s) => s.name === "bar").comment, "the bar itself, its cells and the sweep that runs through them");

const ints = Toml.steps(12, "int");
assert.ok(ints.includes(12) && ints[0] === 0 && ints.length <= 26);
const floats = Toml.steps(1.5, "float");
assert.ok(floats.includes(1.5) && floats[floats.length - 1] >= 3);
assert.ok(Toml.steps(-1, "int").includes(-1));
assert.strictEqual(Toml.steps(120000, "int")[Toml.nearest(Toml.steps(120000, "int"), 120000)], 120000);

const layout = { version: 1, bar: { centerAnchor: "clock", layout: { left: [{ id: "workspaces" }], center: [{ id: "clock" }], right: [{ id: "cpu" }, { id: "memory" }] } } };
const added = Toml.move(layout, null, "github", "left", 1);
assert.deepStrictEqual(added.bar.layout.left.map((e) => e.id), ["workspaces", "github"]);
assert.deepStrictEqual(Toml.move(added, null, "github", "right", 0).bar.layout.right.map((e) => e.id), ["cpu", "memory"]);
const reordered = Toml.move(layout, "right", 0, "right", 2);
assert.deepStrictEqual(reordered.bar.layout.right.map((e) => e.id), ["memory", "cpu"]);
const moved = Toml.move(layout, "right", 1, "center", 0);
assert.deepStrictEqual(moved.bar.layout.center.map((e) => e.id), ["memory", "clock"]);
const removed = Toml.move(layout, "center", 0, null, 0);
assert.strictEqual(Toml.placed(removed, "clock"), false);
assert.strictEqual(removed.bar.centerAnchor, "");
assert.strictEqual(layout.bar.layout.center.length, 1);

console.log("settings toml check ok");
