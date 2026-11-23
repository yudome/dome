const assert = require("assert");
const fs = require("fs");
const path = require("path");

const source = fs.readFileSync(path.join(__dirname, "Slider.qml"), "utf8");
const Calc = { clamp: (value, min, max) => Math.min(Math.max(value, min), max) };

function slider(props) {
	const root = Object.assign({ from: 0, to: 1, stepSize: 0, stops: [], held: -1, value: 0 }, props);
	root.stopCount = root.stops.length;
	const pattern = /^\tfunction (\w+)\(([^)]*)\) \{\n([\s\S]*?)\n\t\}$/gm;
	let match;
	while ((match = pattern.exec(source)) !== null)
		root[match[1]] = new Function("root", "Calc", match[2], match[3]).bind(null, root, Calc);
	return root;
}

const stops = slider({ stops: [{ label: "60", value: 60 }, { label: "120", value: 120 }, { label: "144", value: 144 }] });
assert.strictEqual(stops.normalize(120), 0.5);
assert.strictEqual(stops.normalize(130), 0.5);
assert.strictEqual(stops.valueAt(stops.snap(0.8)), 144);
assert.strictEqual(stops.valueAt(0), 60);
assert.strictEqual(stops.unit(), 0.5);

const text = slider({ stops: ["powersave", "balanced", "performance"] });
assert.strictEqual(text.normalize("performance"), 1);
assert.strictEqual(text.valueAt(text.snap(0.4)), "balanced");

const range = slider({ from: 1, to: 2, stepSize: 0.25 });
assert.strictEqual(range.normalize(1.5), 0.5);
assert.strictEqual(range.valueAt(range.snap(0.6)), 1.5);
assert.strictEqual(range.normalize(9), 1);
assert.strictEqual(range.unit(), 0.25);

const free = slider({ from: 0, to: 10 });
assert.strictEqual(free.valueAt(0.37), 3.7);

console.log("Slider: stops, steps and ranges map both ways");
