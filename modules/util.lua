function trim(text)
	return ((text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
function capture(command)
	return trim(os.iorunv("sh", { "-c", command }))
end
function size_mb(at)
	local total = 0
	for _, file in ipairs(os.files(path.join(at, "**"))) do
		total = total + (os.filesize(file) or 0)
	end
	return math.floor(total / (1024 * 1024))
end
function escape(text)
	return (text:gsub("\\", "\\\\"):gsub('"', '\\"'))
end
