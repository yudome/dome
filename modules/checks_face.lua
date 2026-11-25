function run()
	local twoPi = math.pi * 2

	local function round(x) return math.floor(x + 0.5) end

	local function clamp01(x) return math.max(0, math.min(1, x)) end

	local function superellipseRadius(angle, exponent)
		local cos = math.abs(math.cos(angle))
		local sin = math.abs(math.sin(angle))
		return (cos ^ exponent + sin ^ exponent) ^ (-1 / exponent)
	end

	local function shapePoints(spec)
		local width = math.max(1, spec.width or 1)
		local height = math.max(1, spec.height or 1)
		local exponent = spec.exponent or 2
		local lobes = math.max(0.5, spec.lobes or 1)
		local scallop = math.min(0.9, math.max(0, spec.scallop == nil and 0 or spec.scallop))
		local depth = math.min(0.9, scallop * (spec.morph == nil and 1 or spec.morph))
		local samples = math.max(24, round(spec.samples or 128))
		local cx, cy = width / 2, height / 2
		local points = {}

		for i = 0, samples - 1 do
			local fraction = i / samples
			local angle = fraction * twoPi - math.pi / 2
			local radius = superellipseRadius(angle, exponent)
			local phase = math.fmod(fraction * lobes + 0.5, 1)
			local wave = 1 - depth * (0.5 - 0.5 * math.cos(twoPi * phase))
			points[#points + 1] = cx + radius * math.cos(angle) * cx * wave
			points[#points + 1] = cy + radius * math.sin(angle) * cy * wave
		end
		return points
	end

	local function blendPoints(from, to, progress)
		local amount = clamp01(progress)
		local points = {}
		for i = 1, #from do
			points[i] = from[i] + (to[i] - from[i]) * amount
		end
		return points
	end

	local function rotatePoints(points, cx, cy, angle)
		if angle == 0 then return points end
		local cos, sin = math.cos(angle), math.sin(angle)
		local out = {}
		for i = 1, #points, 2 do
			local x, y = points[i] - cx, points[i + 1] - cy
			out[i] = cx + x * cos - y * sin
			out[i + 1] = cy + x * sin + y * cos
		end
		return out
	end

	local function ellipsePoints(cx, cy, radiusX, radiusY, samples)
		local count = math.max(12, round(samples or 24))
		local points = {}
		for i = 0, count - 1 do
			local angle = (i / count) * twoPi
			points[#points + 1] = cx + math.cos(angle) * radiusX
			points[#points + 1] = cy + math.sin(angle) * radiusY
		end
		return points
	end

	local function roundedRectPoints(cx, cy, halfWidth, halfHeight, radius, samples)
		local count = math.max(2, round((samples or 40) / 4))
		local r = math.min(radius, math.min(halfWidth, halfHeight))
		local points = {}
		local corners = {
			{ cx + halfWidth - r, cy - halfHeight + r, -math.pi / 2 },
			{ cx + halfWidth - r, cy + halfHeight - r, 0 },
			{ cx - halfWidth + r, cy + halfHeight - r, math.pi / 2 },
			{ cx - halfWidth + r, cy - halfHeight + r, math.pi },
		}
		for i = #corners, 1, -1 do
			local corner = corners[i]
			for j = count, 0, -1 do
				local angle = corner[3] + (j / count) * (math.pi / 2)
				points[#points + 1] = corner[1] + math.cos(angle) * r
				points[#points + 1] = corner[2] + math.sin(angle) * r
			end
		end
		return points
	end

	local function socketInside(outline, cx, cy, radiusX, radiusY, samples, margin)
		local total = #outline / 2
		local stride = math.max(1, math.floor(total / 48))
		local count = math.floor(total / stride)
		local gap = margin or 0
		local edge = roundedRectPoints(cx, cy, radiusX + gap, radiusY + gap, math.min(radiusX, radiusY) + gap, samples or 24)

		for i = 1, #edge, 2 do
			local x, y = edge[i], edge[i + 1]
			local insidePoint = false
			for j = 0, count - 1 do
				local k = (j == 0) and count - 1 or j - 1
				local xi = outline[2 * j * stride + 1]
				local yi = outline[2 * j * stride + 2]
				local xk = outline[2 * k * stride + 1]
				local yk = outline[2 * k * stride + 2]
				if ((yi > y) ~= (yk > y)) and x < (xk - xi) * (y - yi) / (yk - yi) + xi then
					insidePoint = not insidePoint
				end
			end
			if not insidePoint then return false end
		end
		return true
	end

	local function clipSockets(outline, sockets, margin)
		local function inside(socket, factor)
			return socketInside(outline, socket.x, socket.y, socket.radiusX * factor, socket.radiusY * factor, 24, margin or 0)
		end
		local low, high = 0, 1
		for _ = 1, 12 do
			local mid = (low + high) / 2
			local ok = true
			for _, socket in ipairs(sockets) do
				if not inside(socket, mid) then ok = false break end
			end
			if ok then low = mid else high = mid end
		end
		local fitted = {}
		for i, socket in ipairs(sockets) do
			fitted[i] = { x = socket.x, y = socket.y, radiusX = socket.radiusX * low, radiusY = socket.radiusY * low }
		end
		return fitted
	end

	local function clampShift(outline, sockets, dx, dy, margin)
		local function fits(t)
			for _, socket in ipairs(sockets) do
				if not socketInside(outline, socket.x + dx * t, socket.y + dy * t, socket.radiusX, socket.radiusY, 8, margin or 0) then
					return false
				end
			end
			return true
		end
		local low, high = 0, 1
		for _ = 1, 8 do
			local mid = (low + high) / 2
			if fits(mid) then low = mid else high = mid end
		end
		return { x = dx * low, y = dy * low }
	end

	local function circleInside(points, cx, cy)
		local radius = math.huge
		for i = 1, #points, 2 do
			radius = math.min(radius, math.sqrt((points[i] - cx) ^ 2 + (points[i + 1] - cy) ^ 2))
		end
		return ellipsePoints(cx, cy, radius, radius, 48)
	end

	local function maxReach(outline, sockets, travel, margin)
		local reaches = {}
		for i = 0, 15 do
			local angle = i / 16 * twoPi
			local shift = clampShift(outline, sockets, math.cos(angle) * travel, math.sin(angle) * travel, margin)
			reaches[i + 1] = math.sqrt(shift.x ^ 2 + shift.y ^ 2)
		end
		local out = {}
		for i = 1, 16 do
			local next = reaches[(i % 16) + 1]
			local previous = reaches[((i - 2) % 16) + 1]
			out[i] = math.min(reaches[i], next, previous)
		end
		return out
	end

	local function reachAt(reaches, angle)
		local count = #reaches
		local at = math.fmod(angle / twoPi * count, count)
		if at < 0 then at = at + count end
		local low = math.floor(at)
		local blend = at - low
		return reaches[low + 1] * (1 - blend) + reaches[(low + 1) % count + 1] * blend
	end

	local size = 44
	local width = size * 0.86
	local height = size * 0.86
	local margin = size * 0.02

	local sockets = {
		{ x = width / 2 - size * 0.22, y = height / 2 - size * 0.04, radiusX = size * 0.105, radiusY = size * 0.185 },
		{ x = width / 2 + size * 0.22, y = height / 2 - size * 0.04, radiusX = size * 0.105, radiusY = size * 0.185 },
	}

	local shapes = {
		idle = { exponent = 2, lobes = 1, scallop = 0 },
		working = { exponent = 2, lobes = 9, scallop = 0.16 },
		blocked = { exponent = 2, lobes = 3, scallop = 0.28 },
		error = { exponent = 1, lobes = 1, scallop = 0 },
	}
	local names = { "idle", "working", "blocked", "error" }

	local function bodyAt(samples, from, to, morph)
		local spec = { width = width, height = height, samples = samples }
		local a, b = {}, {}
		for key, value in pairs(shapes[from]) do a[key] = value end
		for key, value in pairs(shapes[to]) do b[key] = value end
		for key, value in pairs(spec) do a[key] = value b[key] = value end
		return blendPoints(shapePoints(a), shapePoints(b), morph)
	end

	local function socketInsideWhole(outline, cx, cy, radiusX, radiusY, samples, gap)
		local count = #outline / 2
		local edge = roundedRectPoints(cx, cy, radiusX + gap, radiusY + gap, math.min(radiusX, radiusY) + gap, samples)
		for i = 1, #edge, 2 do
			local inside = false
			for j = 0, count - 1 do
				local k = (j == 0) and count - 1 or j - 1
				local xi, yi = outline[2 * j + 1], outline[2 * j + 2]
				local xk, yk = outline[2 * k + 1], outline[2 * k + 2]
				if ((yi > edge[i + 1]) ~= (yk > edge[i + 1])) and edge[i] < (xk - xi) * (edge[i + 1] - yi) / (yk - yi) + xi then
					inside = not inside
				end
			end
			if not inside then return false end
		end
		return true
	end

	local function fitWhole(outline)
		local low, high = 0, 1
		for _ = 1, 12 do
			local mid = (low + high) / 2
			local ok = true
			for _, socket in ipairs(sockets) do
				if not socketInsideWhole(outline, socket.x, socket.y, socket.radiusX * mid, socket.radiusY * mid, 24, margin) then
					ok = false
					break
				end
			end
			if ok then low = mid else high = mid end
		end
		return low
	end

	local failures = {}
	local worst = 0
	local function check(condition, message)
		if not condition then
			failures[#failures + 1] = message
			return false
		end
		return true
	end

	for _, samples in ipairs({ 48, 96, 160, 320 }) do
		for _, from in ipairs(names) do
			for _, to in ipairs(names) do
				for step = 0, 20 do
					local morph = step / 20
					local body = bodyAt(samples, from, to, morph)
					local fitted = clipSockets(body, sockets, margin)
					local reference = fitWhole(body)
					local where = string.format("%s->%s samples=%d morph=%.2f", from, to, samples, morph)
					for i = 1, #fitted do
						local socket = fitted[i]
						if not check(socket.radiusX > 0 and socket.radiusY > 0, "eye vanished at " .. where) then break end
						if not check(socketInsideWhole(body, socket.x, socket.y, socket.radiusX, socket.radiusY, 24, margin - 0.05), "eye lost its margin at " .. where) then break end
						local drift = math.max(math.abs(socket.radiusX - sockets[i].radiusX * reference), math.abs(socket.radiusY - sockets[i].radiusY * reference))
						worst = math.max(worst, drift)
						if not check(drift < 0.15, string.format("eye drifted %.3fpx from the full-outline fit at %s", drift, where)) then break end
					end
					if #failures > 0 then break end
				end
				if #failures > 0 then break end
			end
			if #failures > 0 then break end
		end
		if #failures > 0 then break end
	end

	local function area(points)
		local sum = 0
		local len = #points
		local function at(index)
			return points[(index - 1) % len + 1]
		end
		for i = 1, len, 2 do
			sum = sum + points[i] * at(i + 3) - at(i + 2) * points[i + 1]
		end
		return sum
	end

	for _, name in ipairs(names) do
		check(area(bodyAt(48, name, name, 1)) * area(roundedRectPoints(10, 10, 3, 6, 3, 40)) < 0, "eye winds with the " .. name .. " body")
	end

	for _, name in ipairs(names) do
		local body = bodyAt(160, name, name, 1)
		local fitted = clipSockets(body, sockets, margin)
		local reaches = maxReach(body, fitted, size * 0.055, margin)
		local top = 0
		for _, reach in ipairs(reaches) do top = math.max(top, reach) end
		check(top > 0, "eyes cannot move in the " .. name .. " body")
		for i = 0, 63 do
			local angle = i / 64 * twoPi
			local reach = reachAt(reaches, angle)
			for _, socket in ipairs(fitted) do
				check(socketInsideWhole(body, socket.x + math.cos(angle) * reach, socket.y + math.sin(angle) * reach, socket.radiusX, socket.radiusY, 24, 0), string.format("eye leaves the %s body looking at %d degrees", name, math.floor(angle * 180 / math.pi + 0.5)))
			end
		end
	end

	local body = bodyAt(160, "working", "working", 1)
	local safe = circleInside(body, width / 2, height / 2)
	local fitted = clipSockets(safe, sockets, margin)
	local reaches = maxReach(safe, fitted, size * 0.055, margin)
	for turn = 0, 38, 2 do
		local turned = rotatePoints(body, width / 2, height / 2, turn * math.pi / 180)
		for i = 0, 63 do
			local angle = i / 64 * twoPi
			local reach = reachAt(reaches, angle)
			for _, socket in ipairs(fitted) do
				check(socketInsideWhole(turned, socket.x + math.cos(angle) * reach, socket.y + math.sin(angle) * reach, socket.radiusX, socket.radiusY, 24, 0), string.format("eye crosses the spinning body at %d degrees", turn))
			end
		end
	end

	if #failures > 0 then
		for index = 1, math.min(8, #failures) do
			print(failures[index])
		end
		return false
	end
	print(string.format("AgentFace: eye fit holds, worst drift %.4fpx", worst))
	return true
end
