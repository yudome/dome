pragma Singleton

import QtQuick

QtObject {
	function clamp(value, min, max) { return Math.min(Math.max(value, min), max); }
	function hash(a, b, c) { const n = Math.sin(a * 12.9898 + b * 78.233 + c * 37.719) * 43758.5453; return n - Math.floor(n); }
}
