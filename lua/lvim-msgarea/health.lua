-- lvim-msgarea.health: `:checkhealth lvim-msgarea` — reports that the message zone is loadable, its required
-- deps (lvim-utils base, lvim-ui toolkit, lvim-hud notify hub + cmdline, lvim-picker navigator) are present,
-- the effective zone state, and which optional source integrations (blink.cmp / native completion) are on.
--
---@module "lvim-msgarea.health"

local M = {}

-- The plugin gates Neovim >= 0.12, so `vim.health.{start,ok,warn,error,info}` always exist — no
-- `report_*` fallback shims needed.
local health = vim.health
local start = health.start
local ok = health.ok
local warn = health.warn
local err = health.error
local info = health.info

---@param mod string
---@return boolean
local function has(mod)
    return (pcall(require, mod))
end

function M.check()
    start("lvim-msgarea")

    if vim.fn.has("nvim-0.12") == 1 then
        ok("Neovim >= 0.12")
    else
        err("Neovim >= 0.12 required")
    end

    -- Hard dependencies.
    for _, dep in ipairs({
        { mod = "lvim-utils.utils", name = "lvim-utils (base)" },
        { mod = "lvim-ui.surface", name = "lvim-ui (float toolkit)" },
        { mod = "lvim-hud.notify", name = "lvim-hud (notify hub + cmdline)" },
        { mod = "lvim-picker", name = "lvim-picker (the zone navigator)" },
    }) do
        if has(dep.mod) then
            ok(dep.name .. " is available")
        else
            err(dep.name .. " not found — lvim-msgarea requires it")
        end
    end

    -- The zone drives lvim-ui's zone seams (added for the docked consumers). Missing ⇒ a stale lvim-ui.
    local surf_ok, surf = pcall(require, "lvim-ui.surface")
    if surf_ok and type(surf.set_zone_hooks) == "function" and type(surf.set_host_provider) == "function" then
        ok("lvim-ui exposes the zone seams (set_host_provider / set_zone_hooks)")
    else
        err("lvim-ui is missing the zone seams — update lvim-ui (set_host_provider / set_zone_hooks / zone_handoff)")
    end

    if has("lvim-msgarea") then
        ok("lvim-msgarea loaded")
    else
        err("lvim-msgarea failed to load")
    end

    -- Effective state.
    local cfg = require("lvim-msgarea.config")
    start("lvim-msgarea · state")
    if cfg.enable then
        ok("zone enabled")
    else
        info("zone disabled (opt-in: enable = true, or :LvimMsgArea to toggle)")
    end
    if cfg.unified then
        ok("unified minibuffer on (the cmdline docks at the bottom of the zone)")
    else
        info("unified minibuffer off (the cmdline keeps its own float)")
    end
    local integ = cfg.integrations or {}
    for _, name in ipairs({ "blink", "native" }) do
        if integ[name] then
            ok("integration '" .. name .. "' enabled")
        else
            info("integration '" .. name .. "' disabled")
        end
    end
    if integ.blink and not has("blink.cmp.config") then
        warn("the blink integration is on but blink.cmp is not installed")
    end
end

return M
