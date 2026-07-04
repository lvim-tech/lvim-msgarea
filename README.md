# lvim-msgarea

The persistent **message area** of the **lvim-tech** set — a toggleable, Emacs-minibuffer-style zone docked
under (or over) the editor, where messages **stay readable** instead of vanishing after a timeout or on the
next cursor move.

It is not a second `vim.ui_attach` and does not patch any Neovim internals. The notify hub (lvim-hud) is the
single `ext_messages` owner; it captures / de-dups / levels every message and routes it by kind. lvim-msgarea
registers a **sink** with that hub and renders whatever is routed to it into a window it owns — so it inherits
all of notify's message handling. On top of that it can host:

- the **unified minibuffer** — the command-line (`:` `/` `?`) drawn at the bottom of the zone instead of its
  own float;
- the **`:Messages` history** — browsed inside the zone (a filter bar with level filters);
- **completion docks** — blink.cmp or the native cmdline completion menu, rendered in the zone above the
  command line (opt-in source integrations).

## Requirements

Requires **Neovim >= 0.12.x** and four lvim-tech plugins:
[lvim-utils](https://github.com/lvim-tech/lvim-utils) (base),
[lvim-ui](https://github.com/lvim-tech/lvim-ui) (the float toolkit + the zone seams),
[lvim-hud](https://github.com/lvim-tech/lvim-hud) (the notify hub + the command-line) and
[lvim-picker](https://github.com/lvim-tech/lvim-picker) (the in-zone navigator). Optional: `blink.cmp` for the
blink completion dock.

## Installation

### lvim-installer (recommended)

```vim
:LvimInstaller plugins
```

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-hud" },
    { src = "https://github.com/lvim-tech/lvim-picker" },
    { src = "https://github.com/lvim-tech/lvim-msgarea" },
})
require("lvim-msgarea").setup({ enable = true })
```

## Usage

`setup()` registers `:LvimMsgArea` (toggle the zone) and, when `enable = true`, turns it on. The zone opens
automatically when a message is routed to it and hides when it empties.

```vim
:LvimMsgArea
```

```lua
local ma = require("lvim-msgarea")
ma.toggle() -- show / hide the zone (the model is kept)
ma.enable() -- turn the zone on   (register the sink + route kinds)
ma.disable() -- turn the zone off
ma.focus_messages() -- focus the zone to browse the message history
ma.clear() -- wipe the scrollback
```

The unified minibuffer (`unified = true`) needs `lvim-hud.cmdline` enabled; the completion docks
(`integrations.blink` / `integrations.native`) route the respective completion menu into the zone.

## Configuration

`setup()` merges your options into the live config in place (a shorter override list replaces the default
wholesale). The full default config:

```lua
require("lvim-msgarea").setup({
    enable = false, -- master switch (live-toggleable via :LvimMsgArea)

    -- Height — `max_height` is the only hard rule. Both heights: >=1 = absolute lines, <1 = a fraction.
    max_height = 10, -- the panel is never taller than this
    auto_resize = true, -- fit content up to the cap (true) vs always max_height (false)
    min_height = 1, -- floor while auto-resizing

    focusable = true, -- the zone can be focused (to scroll / interact) — never auto-focused

    -- Unified minibuffer: draw the cmdline (`:` `/` `?`) at the bottom of the zone (needs lvim-hud.cmdline).
    unified = false,

    -- Content
    scrollback = 500, -- max retained message lines (ring buffer)
    completion_max = 12, -- max intercepted completion rows shown at once
    completion_columns = 1, -- 1 = a list; 2/3/4… = a row-major grid
    completion_hidden = true, -- (native) include hidden dotfiles/folders in file/dir completion
    -- (native) the command-line keymaps that drive the completion grid (action -> keys; {} to unbind).
    completion_keys = {
        next = { "<C-j>", "<C-n>" }, -- selection down a grid row
        prev = { "<C-k>", "<C-p>" }, -- selection up a grid row
        right = { "<C-l>" }, -- one cell right
        left = { "<C-h>" }, -- one cell left
        accept = { "<Tab>" }, -- accept / drill into the selected candidate
        drill_out = { "<S-Tab>" }, -- back up a path segment
        enter = { "<CR>" }, -- complete the selection first, then execute
    },
    wrap = true, -- soft-wrap long lines
    follow = true, -- tail: keep the newest line in view on append
    dedup = true, -- collapse a repeated consecutive message into "message  (xN)"
    icons = true, -- a per-level icon badge (reuses notify's level icons)
    timestamps = false, -- prefix each message with its capture time
    time_format = "%H:%M:%S",

    -- Chrome
    winbar = false, -- a thin title / summary row at the top of the panel
    title = "Messages",

    -- Routing: which message kinds land in the zone (folded into notify's ext_kinds when enabled).
    -- "zone" = the styled history view (clean tinted lines; the filter bar appears when focused).
    kinds = {
        lua_error = "zone",
        emsg = "zone",
        echoerr = "zone",
        echomsg = "zone",
        echo = "zone",
        wmsg = "zone",
        shell_out = "zone",
        shell_err = "zone",
    },

    -- Opt-in source integrations that route another UI into the zone.
    integrations = {
        blink = false, -- blink.cmp completion menu docks at the zone (above the command line)
        native = false, -- native cmdline completion docks at the zone
    },

    -- Keys active only while the panel is focused.
    keys = {
        close = "q", -- hide the panel (the model is kept)
        clear = "C", -- wipe the scrollback
        scroll_up = "<C-u>",
        scroll_down = "<C-d>",
        top = "gg",
        bottom = "G",
    },
})
```

## License

BSD-3-Clause.
