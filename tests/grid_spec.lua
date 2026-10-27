-- The completion grid, rendered through the real zone.
--
-- Everything that matters here is in the cells: each row must be exactly as wide as the screen
-- (a short row leaves the zone's background ragged), a cell must keep a free trailing column so
-- adjacent columns never touch, a label too long for its cell is cut in DISPLAY CELLS with an
-- ellipsis, and the grid must scroll to keep the selection visible instead of rendering past its
-- row budget.
--
-- It is driven through the public segment handle and read back out of the zone's own buffer, so
-- what the suite measures is what the user would see -- not an internal function's return value.

local msgarea = require("lvim-msgarea")

--- Render `items` as a grid through a segment and hand back the zone's lines.
---@param items table[]
---@param selected integer?
---@param opts table?
---@return string[]
local function grid(items, selected, opts)
    local handle = msgarea.segment("lvim-msgarea-grid-spec", { kind = "grid", priority = 50 })
    handle:set_grid(items, selected, opts)

    local found = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].filetype == "lvim-ui-frame" then
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            for _, l in ipairs(lines) do
                if l:match("%S") then
                    found[#found + 1] = l
                end
            end
        end
    end
    handle:release()
    return found
end

--- `n` plain items, labelled so a row can be identified.
---@param n integer
---@param prefix? string
---@return table[]
local function items(n, prefix)
    local out = {}
    for i = 1, n do
        out[i] = { text = (prefix or "item_") .. i }
    end
    return out
end

local enabled = pcall(msgarea.enable) and msgarea.is_enabled()

if not enabled then
    describe("lvim-msgarea: the completion grid")
    skip("the completion grid", "the message zone could not be enabled in this environment")
    return
end

describe("lvim-msgarea: the completion grid")

it("one item per row by default, each row the full screen width", function()
    local lines = grid(items(3))
    eq(3, #lines)
    for i, l in ipairs(lines) do
        eq(vim.o.columns, vim.fn.strdisplaywidth(l), "row " .. i .. ": " .. vim.inspect(l))
        truthy(l:match("item_" .. i), vim.inspect(l))
    end
end)

it("several columns split the width evenly, and no row overruns the screen", function()
    -- The cells are equal: floor(columns / C) each. With a C that does not divide the screen the row
    -- is a cell-remainder short -- measured, 78 of 80 at three columns -- and that is deliberate
    -- rather than ragged: the row carries an `eol` highlight span, so the stripe covers the rest of
    -- the screen line. What must never happen is a row WIDER than the screen, which would wrap and
    -- push the zone's own rows apart.
    for _, cols in ipairs({ 1, 2, 3, 4 }) do
        local lines = grid(items(8), nil, { columns = cols })
        eq(math.ceil(8 / cols), #lines, cols .. " columns")

        local expected = cols * math.floor(vim.o.columns / cols)
        for _, l in ipairs(lines) do
            local w = vim.fn.strdisplaywidth(l)
            eq(expected, w, cols .. " columns: " .. vim.inspect(l))
            truthy(w <= vim.o.columns, "a row wider than the screen wraps: " .. w)
            truthy(vim.o.columns - w < cols, "the shortfall is at most one cell's rounding")
        end
    end
end)

it("items fill the grid row by row", function()
    local lines = grid(items(4), nil, { columns = 2 })
    eq(2, #lines)
    truthy(lines[1]:match("item_1"), lines[1])
    truthy(lines[1]:match("item_2"), "the second item belongs beside the first, not below it")
    truthy(lines[2]:match("item_3"), lines[2])
end)

it("a cell always keeps a free trailing column", function()
    -- Labels longer than any cell: the truncation must still leave the last column blank, or two
    -- adjacent cells touch and read as one word.
    local long = {}
    for i = 1, 4 do
        long[i] = { text = ("long_label_%d"):rep(6):format(i, i, i, i, i, i) }
    end
    local lines = grid(long, nil, { columns = 2 })
    local cell_w = math.floor(vim.o.columns / 2)
    for _, l in ipairs(lines) do
        local first = vim.fn.strcharpart(l, 0, cell_w)
        eq(
            " ",
            vim.fn.strcharpart(first, cell_w - 1, 1),
            "the cell's last column must be blank: " .. vim.inspect(first)
        )
    end
end)

it("a label too long for its cell is cut with an ellipsis", function()
    local lines = grid({ { text = ("x"):rep(500) } })
    eq(1, #lines)
    truthy(lines[1]:match("…"), "a cut label has to say it was cut: " .. vim.inspect(lines[1]:sub(1, 40)))
    eq(vim.o.columns, vim.fn.strdisplaywidth(lines[1]))
end)

it("a multibyte label is cut by display cells, not by bytes", function()
    local lines = grid({ { text = ("日本語"):rep(100) } })
    eq(vim.o.columns, vim.fn.strdisplaywidth(lines[1]), "a byte-based cut would leave the row short or long")
    truthy(lines[1]:match("…"))
end)

it("a label that fits in CELLS is not cut for having more BYTES than that", function()
    -- The trap: "日本語" is six display cells but nine bytes. With eight columns the cell body has
    -- room for eight cells, so the label fits whole -- but a length check written in bytes sees nine
    -- against eight and truncates a label that was never too long.
    local lines = grid({ { text = "日本語" } }, nil, { columns = 8 })
    eq(1, #lines)
    local cell_w = math.floor(vim.o.columns / 8)
    local first = vim.fn.strcharpart(lines[1], 0, cell_w)
    truthy(first:match("日本語"), "the label was cut although it fits: " .. vim.inspect(first))
    eq(nil, first:match("…"), vim.inspect(first))
end)

it("a label with a newline in it stays one row", function()
    local lines = grid({ { text = "first\nsecond" } })
    eq(1, #lines, "a grid cell is one row: " .. vim.inspect(lines))
    truthy(lines[1]:match("first second"), "the newline becomes a space: " .. vim.inspect(lines[1]))
end)

it("an icon precedes the label", function()
    local lines = grid({ { text = "named", icon = "I" } })
    truthy(lines[1]:match("I%s+named"), vim.inspect(lines[1]))
end)

describe("lvim-msgarea: the grid scrolls to the selection")

it("the row budget is honoured", function()
    local lines = grid(items(30), nil, { columns = 1, max_rows = 5 })
    eq(5, #lines, "thirty items may not render thirty rows")
end)

it("a selection below the budget scrolls the window down to it", function()
    local lines = grid(items(30), 20, { columns = 1, max_rows = 5 })
    eq(5, #lines)
    local shown = table.concat(lines, "\n")
    truthy(shown:match("item_20"), "the selected item has to be on screen: " .. vim.inspect(lines))
    eq(nil, shown:match("item_1[^0-9]"), "and the top of the list is scrolled away")
end)

it("a selection inside the budget leaves the window at the top", function()
    local lines = grid(items(30), 2, { columns = 1, max_rows = 5 })
    truthy(table.concat(lines, "\n"):match("item_1[^0-9]"), "nothing needs scrolling yet")
end)

it("the last item selected scrolls to the end of the list", function()
    local lines = grid(items(30), 30, { columns = 1, max_rows = 5 })
    truthy(table.concat(lines, "\n"):match("item_30"), vim.inspect(lines))
end)

it("an empty grid renders nothing at all", function()
    eq({}, grid({}))
end)
