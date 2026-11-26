local function switcherOpen()
    for _, layer in ipairs(hl.get_layers({ namespace = "launcher" })) do
        if layer.keyboard_interactivity == 1 then return true end
    end

    return false
end

local function focusTarget(direction)
    local current = hl.get_active_window()
    if not current then return nil end

    local cx = current.at.x + current.size.x / 2
    local cy = current.at.y + current.size.y / 2
    local wsid = current.workspace.id
    local best, bestScore = nil, nil

    for _, w in ipairs(hl.get_windows()) do
        if w.address ~= current.address and w.mapped and not w.hidden and w.workspace.id == wsid then
            local dx = w.at.x + w.size.x / 2 - cx
            local dy = w.at.y + w.size.y / 2 - cy
            local along, across

            if direction == "left" then
                along, across = -dx, math.abs(dy)
            elseif direction == "right" then
                along, across = dx, math.abs(dy)
            elseif direction == "up" then
                along, across = -dy, math.abs(dx)
            else
                along, across = dy, math.abs(dx)
            end

            if along > 0 then
                local score = along * along + 4 * across * across

                if not bestScore or score < bestScore then
                    best, bestScore = w, score
                end
            end
        end
    end

    return best
end

local function step(direction)
    return function()
        if switcherOpen() then
            hl.exec_cmd("qs ipc call shell windowsStep " .. direction)
            return
        end

        local target = focusTarget(direction)

        if target then
            hl.dispatch(hl.dsp.focus({ window = target }))
            return
        end

        hl.dispatch(hl.dsp.focus({ direction = direction }))
    end
end

local function move(direction)
    return function()
        local win = hl.get_active_window()
        if not win or win.floating then
            hl.dispatch(hl.dsp.window.move({ direction = direction }))
            return
        end

        local vertical = direction == "up" or direction == "down"
        local count, neighbor = 0, nil

        for _, w in ipairs(hl.get_windows()) do
            if w.address ~= win.address and w.mapped and not w.hidden
               and not w.floating and w.workspace.id == win.workspace.id then
                count = count + 1
                neighbor = w
            end
        end

        if count == 1 and neighbor and not focusTarget(direction) then
            local overlapY = math.min(win.at.y + win.size.y, neighbor.at.y + neighbor.size.y)
                - math.max(win.at.y, neighbor.at.y)
            local overlapX = math.min(win.at.x + win.size.x, neighbor.at.x + neighbor.size.x)
                - math.max(win.at.x, neighbor.at.x)
            local sameRow = vertical and overlapY > 0
            local sameCol = not vertical and overlapX > 0

            if sameRow or sameCol then
                hl.dispatch(hl.dsp.layout("togglesplit"))

                local moved = hl.get_active_window()
                local other = hl.get_window("address:" .. neighbor.address) or neighbor

                if moved and other then
                    local wrong = vertical
                        and ((direction == "up" and moved.at.y > other.at.y)
                            or (direction == "down" and moved.at.y < other.at.y))

                    if wrong then
                        hl.dispatch(hl.dsp.window.move({ direction = direction }))
                    end
                end

                return
            end
        end

        hl.dispatch(hl.dsp.window.move({ direction = direction }))
    end
end

return {
    step = step,
    move = move,
}
