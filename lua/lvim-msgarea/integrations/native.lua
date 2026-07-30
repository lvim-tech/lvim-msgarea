-- lvim-msgarea.integrations.native: NATIVE command-line completion ↔ msgarea: the ENGINE is Neovim's own `getcompletion` (no plugin), the
-- VIEW is the message zone. On every change of a `:` command line we compute the completion candidates and
-- render them IN the area via the public "completion" SEGMENT — AUTOMATICALLY (no <Tab> needed), exactly
-- like the blink integration but with the built-in completion as the source. Navigation + accept are driven
-- by the consumer's cmdline keymaps (the same grid_*/accept/enter API blink exposes), so the user can swap
-- `integrations = { blink = true }` for `{ native = true }` and keep the same keys. Insert-mode / LSP
-- completion is left to the native popup at the cursor — only the COMMAND LINE is mirrored here.
--
---@module "lvim-msgarea.integrations.native"

local api = vim.api
local fuzzy = require("lvim-picker.fuzzy")
local config = require("lvim-msgarea.config")

local M = {}

---@type integer? autocmd group
local augroup = nil
---@type table[]  the current candidate items ({ text = word, match? }), in display order
local items = {}
---@type integer  the selected 1-based index (0 = none)
local sel = 0
---@type integer  bumped each refresh; the async fuzzy callback applies only if it is still the latest
local gen = 0
---@type boolean  true while a coalesced refresh is already queued for this tick — so a burst of
--- CmdlineChanged (a pasted word, held key) schedules ONE getcompletion pass, not N (refresh reads the
--- live cmdline when it runs, so the single pass sees the final text).
local refresh_pending = false

--- The msgarea module (loose require so this can load without it).
---@return table?
local function area()
    local ok, m = pcall(require, "lvim-msgarea")
    return ok and m or nil
end

--- Grid layout opts read from the msgarea config (columns / max visible rows).
---@return integer columns, integer? max_rows
local function grid_opts()
    local mc = config or {}
    return mc.completion_columns or 1, mc.completion_max
end

--- True while a command line we mirror is active: a `:` command, or a `vim.fn.input()` PROMPT that declares
--- a completion kind. Search / insert are left native.
--- The prompt case is why `:e ~/co<Tab>` listed candidates while an lvim-space "Project path" field looked
--- dead: the value completes natively either way, but with nothing rendered there is no sign it did, and no
--- grid to step through. Neovim reports a prompt's kind through `getcmdcompltype()` ("dir", "file", …), so
--- the same mirror works for both.
---@return boolean
local function in_cmd()
    local t = vim.fn.getcmdtype()
    if t == ":" then
        return true
    end
    return t == "@" and vim.fn.getcmdcompltype() ~= ""
end

--- True while the active command line is an input() PROMPT (as opposed to a `:` command).
---@return boolean
local function in_prompt()
    return vim.fn.getcmdtype() == "@"
end

--- Recompute the native completion candidates for the current command line, FUZZY-rank them, and render
--- them in the zone. To make completion fuzzy (`:Lvc` → `LvimColorscheme`, not just prefix matches) we
--- BROADEN the candidate set: split the line into a `stem` (up to the last space) + the `token` being
--- completed, keep only the token's path-prefix (the directory for a path, empty for a command/option), ask
--- Neovim for everything in that context, then fuzzy-rank by the rest of the token. Async (fuzzy may spawn
--- fzf); a generation guard drops a stale callback. Empty line / no candidates ⇒ clear.
local function refresh()
    local m = area()
    if not m then
        return
    end
    gen = gen + 1
    local mygen = gen
    if not in_cmd() then
        items, sel = {}, 0
        m.clear_completion()
        return
    end
    local line = vim.fn.getcmdline()
    if line == "" then -- nothing typed yet — don't dump the entire command list
        items, sel = {}, 0
        m.clear_completion()
        return
    end
    -- A PROMPT has no command word in front of the value, and a path may legitimately contain spaces
    -- ("nvim (another copy)"), so the whole line is the token there. A `:` line splits at the last space.
    local prompt = in_prompt()
    local stem, token
    if prompt then
        stem, token = "", line
    else
        stem, token = line:match("^(.*%s)(%S*)$")
        if not stem then
            stem, token = "", line
        end
    end
    local bprefix = token:match("^(.*/)") or "" -- the path-prefix (dir) of the token; "" for a command/option
    local fz = token:sub(#bprefix + 1) -- the part fuzzy-matched against the broadened candidates
    -- `cmdline` resolves a whole `:` line (command + args); a prompt has no command, so ask for its own kind.
    local kind = prompt and vim.fn.getcmdcompltype() or "cmdline"
    local ok, cands = pcall(vim.fn.getcompletion, stem .. bprefix, kind)
    if not ok or not cands then
        cands = {}
    end
    -- getcompletion omits dotfiles unless the prefix has a leading dot. For FILE/DIR completion with
    -- `completion_hidden`, fetch the dotfile variant (`<prefix>.`) too and merge — dropping the `.`/`..`
    -- pseudo-entries — so hidden files/folders are fuzzy-completable.
    local mc = config or {}
    local ctype = vim.fn.getcmdcompltype()
    if mc.completion_hidden ~= false and (ctype:find("file") or ctype:find("dir")) then
        local okh, hidden = pcall(vim.fn.getcompletion, stem .. bprefix .. ".", kind)
        if okh and hidden then
            for _, h in ipairs(hidden) do
                local base = h:match("[^/]*/?$")
                if base ~= "./" and base ~= "../" and base ~= "." and base ~= ".." then
                    cands[#cands + 1] = h
                end
            end
        end
    end
    if #cands == 0 then
        items, sel = {}, 0
        m.clear_completion()
        return
    end
    -- DISPLAY the last path segment only (the basename) so deep paths don't overflow the grid, but keep the
    -- FULL candidate for accept. Fuzzy-match + sort on the basenames (cleaner than matching the whole path).
    local bases = {}
    for i, c in ipairs(cands) do
        bases[i] = c:match("[^/]*/?$") or c -- "~/foo/bar/baz.lua" → "baz.lua"; "dir/" → "dir/"; a command → itself
    end
    fuzzy.filter(bases, fz, function(ranked)
        if mygen ~= gen or not in_cmd() then -- a newer keystroke superseded this, or the cmdline closed
            return
        end
        items = {}
        for i, r in ipairs(ranked) do
            items[i] = { text = bases[r.idx], full = cands[r.idx], match = r.match }
        end
        if #items == 0 then
            sel = 0
            m.clear_completion()
            return
        end
        -- Preselect the best match ONLY while a fragment is being TYPED (so <CR> completes a partial command
        -- / option, e.g. `:LvimPick`→`LvimPicker`). The test is `fz` — what is left to complete — not the
        -- whole token, because a token can be COMPLETE while still having candidates under it:
        --   `:LvimInstaller ` → token "" → its subcommands are offered, <CR> runs the bare command
        --   `:e ~/.config/`   → token "~/.config/", fz "" → its ENTRIES are offered, <CR> opens the directory
        -- Keying on the token made the second case preselect the first entry, so <CR> on a finished directory
        -- silently descended into it (`:e ~/.config/` became `:e ~/.config/Android Open Source Project/`, and
        -- an lvim-space "Project path" gained a subdirectory the user never asked for). A trailing separator
        -- means the path so far IS the answer; the list below it is a convenience, not a pending choice.
        -- <Tab> still selects from here either way.
        sel = (fz == "") and 0 or 1
        m.set_completion(items, sel)
    end)
end

--- Move the selection by `delta` (clamped) and re-render just the selection (cheap path).
---@param delta integer
local function move(delta)
    if #items == 0 then
        return false
    end
    sel = math.max(1, math.min(#items, sel + delta))
    local m = area()
    if m then
        m.set_completion_selected(sel)
    end
    return true
end

-- ── public navigation API (mirrors the blink integration) ──────────────────────

--- True when a completion menu is currently shown (candidates available) — so a cmdline keymap can decide
--- to consume the key (and schedule the action OUTSIDE textlock) vs fall through to the default behaviour.
---@return boolean
function M.has_menu()
    return #items > 0
end

--- True when accepting the current selection WOULD change the command line (there is something to fill) —
--- read-only, so it is safe to call synchronously from an expr keymap. Lets `<CR>` complete first when the
--- token is still partial (avoids running an ambiguous command), then execute once it is complete.
---@return boolean
function M.would_fill()
    if #items == 0 or sel < 1 then
        return false
    end
    local cand = items[sel].full or items[sel].text
    local line = vim.fn.getcmdline()
    local stem = line:match("^(.*%s)%S*$") or ""
    return (stem .. cand) ~= line
end

--- Move down a whole grid ROW (by the column count).
---@return boolean handled
function M.grid_down()
    local cols = select(1, grid_opts())
    return move(cols)
end

--- Move up a whole grid ROW.
---@return boolean handled
function M.grid_up()
    local cols = select(1, grid_opts())
    return move(-cols)
end

--- Move one cell right.
---@return boolean handled
function M.grid_right()
    return move(1)
end

--- Move one cell left.
---@return boolean handled
function M.grid_left()
    return move(-1)
end

--- Accept the selected candidate: replace the last whitespace-delimited token of the command line with it
--- (handles `:hel`→`help`, `:e /tm`→`/tmp/`, `:color dese`→`desert`). `setcmdline` fires CmdlineChanged, so
--- the zone re-completes for the new token (drilling into a directory just works). Returns false when there
--- is nothing to accept (so the key can fall through).
---@return boolean handled
function M.accept()
    if #items == 0 or sel < 1 then
        return false
    end
    local cand = items[sel].full or items[sel].text -- the FULL candidate (path), not the basename display
    local line = vim.fn.getcmdline()
    -- A prompt's whole line is the value (paths may contain spaces); a `:` line keeps everything up to and
    -- including the last space. Must match how `refresh` split the token, or accept writes a mangled line.
    local stem = in_prompt() and "" or (line:match("^(.*%s)%S*$") or "")
    pcall(vim.fn.setcmdline, stem .. cand)
    return true
end

--- Drill OUT: strip the last path segment of the current token (go up a directory), then re-complete.
--- `:e ~/foo/bar` → `:e ~/foo/`. No path separator ⇒ not handled (the key falls through).
---@return boolean handled
function M.drill_out()
    local line = vim.fn.getcmdline()
    -- the last whitespace-delimited token is the path being completed
    local stem, token = line:match("^(.*%s)(%S*)$")
    if not stem then
        stem, token = "", line
    end
    if not token:find("/") then
        return false
    end
    -- drop the trailing segment after the last slash (keep the slash): "~/foo/bar" → "~/foo/"
    local up = token:gsub("[^/]*/?$", "")
    pcall(vim.fn.setcmdline, stem .. up)
    return true
end

--- <CR>: accept the selection if the menu is open, else let the command line execute (fallback).
---@return boolean handled
function M.enter()
    if #items > 0 and sel >= 1 then
        return M.accept()
    end
    return false
end

-- ── cmdline keymaps (from config.completion_keys) ──────────────────────

-- action name → the public method it invokes.
---@type table<string, string>
local KEY_ACTIONS = {
    next = "grid_down",
    prev = "grid_up",
    right = "grid_right",
    left = "grid_left",
    accept = "accept",
    drill_out = "drill_out",
    enter = "accept", -- special-cased in install_keys: complete-then-execute
}

---@type string[]  the cmdline lhs's we installed (to delete on disable)
local mapped_keys = {}
---@type table<string, table>  lhs → the user's pre-existing cmdline maparg dict (`{}` = none), captured on
--- install so `remove_keys` can restore it verbatim instead of leaving the lhs unmapped.
local saved_maps = {}

--- <C-z>: the conventional 'wildcharm' — a key with no meaning as command-line text.
local WILDCHARM = 26

--- Make 'wildcharm' available for the fall-through below. MUST run when the maps are INSTALLED, not on the
--- first keypress: setting it from inside the expr map is too late for the very key that triggered it (the
--- first <Tab> in a prompt was swallowed and only the second completed — measured), because the returned
--- <C-z> is processed against the value in force before the mapping ran.
local function ensure_wildcharm()
    if vim.o.wildcharm == 0 then
        vim.o.wildcharm = WILDCHARM
    end
end

--- The fall-through key for an lhs that is the 'wildchar'. Returning the literal key from an expr map does
--- NOT complete: 'wildchar' is recognised as it is TYPED, before mappings, so a `<Tab>` handed back by a
--- mapping is inserted as a plain character and native completion never runs. 'wildcharm' exists for exactly
--- this — it is the character that DOES trigger completion from inside a mapping, so return that instead.
--- Without this, every command-line completion that our own grid does not drive is dead: a `vim.fn.input()`
--- prompt with a `completion` kind (an lvim-space "Project path" field, say) swallowed <Tab> and typed a
--- literal tab instead of completing the path.
---@param lhs string
---@return string  the termcodes to return from the expr map
local function fallthrough(lhs)
    local key = api.nvim_replace_termcodes(lhs, true, false, true)
    if key == api.nvim_replace_termcodes(vim.fn.nr2char(vim.o.wildchar), true, false, true) then
        return api.nvim_replace_termcodes("<C-z>", true, false, true)
    end
    return key
end

--- Install the command-line keymaps from `config.completion_keys`. Each runs as an EXPR map so it
--- can decide consume-vs-fall-through: when a menu is open it SCHEDULES the action (the move/accept changes
--- the zone's window+buffer — forbidden under the expr textlock, E565) and otherwise the key falls through
--- to its native cmdline behaviour (see `fallthrough` for why 'wildchar' needs 'wildcharm' to do that). Any
--- user cmdline mapping the lhs already had is snapshotted first (and restored on disable), so an
--- enable/disable cycle never destroys a `cnoremap`.
local function install_keys()
    local keys = (config or {}).completion_keys or {}
    ensure_wildcharm()
    for action, method in pairs(KEY_ACTIONS) do
        for _, lhs in ipairs(keys[action] or {}) do
            if saved_maps[lhs] == nil then
                -- capture ONCE per lhs (before we overwrite it), even if two actions share a key
                saved_maps[lhs] = vim.fn.maparg(lhs, "c", false, true)
            end
            vim.keymap.set("c", lhs, function()
                -- `enter` is special: complete the selection FIRST while the token is still partial (so an
                -- ambiguous command like `:LvimPick` is filled, not run → no E464), and only fall through to
                -- execute once there is nothing left to fill.
                if action == "enter" then
                    if M.has_menu() and M.would_fill() then
                        vim.schedule(M.accept)
                        return ""
                    end
                    return fallthrough(lhs)
                end
                if M.has_menu() then
                    vim.schedule(function()
                        pcall(M[method])
                    end)
                    return ""
                end
                return fallthrough(lhs)
            end, { expr = true, silent = true })
            mapped_keys[#mapped_keys + 1] = lhs
        end
    end
end

--- Remove the installed cmdline keymaps and restore any user mapping the lhs had before we installed ours.
local function remove_keys()
    for _, lhs in ipairs(mapped_keys) do
        pcall(vim.keymap.del, "c", lhs)
        local prev = saved_maps[lhs]
        if type(prev) == "table" and not vim.tbl_isempty(prev) then
            pcall(vim.fn.mapset, "c", false, prev) -- put the user's original cmdline map back
        end
    end
    mapped_keys = {}
    saved_maps = {}
end

-- ── lifecycle ──────────────────────────────────────────────────────────────────

--- Turn the integration on: mirror every `:` command-line change into the zone's completion grid + install
--- the command-line navigation keymaps.
function M.enable()
    if augroup then
        return
    end
    install_keys()
    augroup = api.nvim_create_augroup("LvimUtilsMsgAreaNative", { clear = true })
    api.nvim_create_autocmd("CmdlineChanged", {
        group = augroup,
        callback = function()
            -- Defer: a `setcmdline()` (from accept/drill) fires CmdlineChanged under TEXTLOCK, where the zone
            -- render's buffer writes are forbidden (E565). Scheduling runs the refresh outside textlock. Coalesce
            -- a burst into ONE pass (refresh reads the live cmdline when it runs) so a pasted word does not fire
            -- N getcompletion scans.
            if in_cmd() and not refresh_pending then
                refresh_pending = true
                vim.schedule(function()
                    refresh_pending = false
                    refresh()
                end)
            end
        end,
    })
    api.nvim_create_autocmd("CmdlineLeave", {
        group = augroup,
        callback = function()
            -- Reset the plain-Lua state synchronously (so has_menu() is instantly false for any in-flight
            -- expr map), but DEFER the zone render — clear_completion writes the zone buffer, forbidden under
            -- the CmdlineLeave textlock (E565), exactly like the CmdlineChanged sibling above.
            items, sel = {}, 0
            vim.schedule(function()
                local m = area()
                if m then
                    pcall(m.clear_completion)
                end
            end)
        end,
    })
end

--- Turn it off + drop any shown completion + remove the keymaps.
function M.disable()
    if augroup then
        pcall(api.nvim_del_augroup_by_id, augroup)
        augroup = nil
    end
    remove_keys()
    items, sel = {}, 0
    local m = area()
    if m then
        pcall(m.clear_completion)
    end
end

return M
