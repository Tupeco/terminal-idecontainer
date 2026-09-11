# Tips

Things in here that are easy to get wrong or hard to discover. The README
covers what is installed and why; this covers how to actually drive it.

## Quick reference

The commands worth having in muscle memory. Everything here is explained further
down; `<leader>` is the space bar.

This section doubles as nvim's startup screen. `nvim` with no arguments, or
`nvim .`, renders it into the empty editor window — `q` or `i` dismisses it.
`:Tips` opens this whole file in a float at any time, `q` to close.

It is generated from the tables below rather than duplicated, and TIPS.md is
bind-mounted into the container, so editing this file updates the editor with no
rebuild. Keep new entries as two-column table rows and they will appear there
automatically; prose is skipped.

**Project and files**

| | |
|---|---|
| `nvim .` | Open a project: file tree left, editor right |
| `<leader>tt` | Toggle the file tree |
| `<leader>tf` | Reveal the current file in the tree |
| `<leader>ff` | Find a file by name |
| `<leader>fg` | Search file contents |

**Windows and splits**

| | |
|---|---|
| `:sp` / `:vs` | Split the *current* window |
| `:bo sp` / `:bo vs` | Split at the root: full-width bottom / full-height right |
| `:to sp` / `:to vs` | Same, at the top / far left |
| `<C-w>` then `hjkl` | Move between windows |
| `<C-w>` then `HJKL` | Move *this* window to an edge, spanning the full width or height |
| `<C-w>=` | Even out the sizes |

`:bo` and `:to` abbreviate `:botright` and `:topleft`. The capitals are the fix
when a window ends up nested somewhere you did not want it: `<C-w>J` makes the
current window the full-width bottom one again.

**Buffers**

| | |
|---|---|
| `<leader>fb` | Jump to an open file |
| `:ls` | List open buffers |
| `:b <partial>` | Jump by name, with `<Tab>` completion |
| `<C-^>` | Flip to the previous file |
| `<C-o>` / `<C-i>` | Back / forward through where you have been |

**Terminal and scratch buffers**

| | |
|---|---|
| `:terminal` | Shell in the current window; `:bo sp \| te` for a bottom strip |
| `<C-\><C-n>` | Leave terminal insert mode |
| `:file <name>` | Name a terminal or scratch buffer so `:ls` shows something useful |

`:file` on a **file** buffer is a rename, not a label — your next `:w` writes
somewhere new and silently leaves the original alone. See
[Naming a buffer](#naming-a-buffer).

**Diffs and history**

| | |
|---|---|
| `:DiffviewOpen main..feature` | Whole-repo diff between two revisions |
| `<leader>gd` | Diff the working tree |
| `<leader>gh` | History of the current file |
| `]c` / `[c` | Next / previous change within the file |
| `zR` / `zM` | Show / hide the unchanged lines |
| `git diff main..feature` | The same in the shell; `n`/`N` move between files |

**Code**

| | |
|---|---|
| `gd` / `grr` | Definition / references |
| `K` | Hover docs |
| `<leader>ca` | Code action |
| `[d` / `]d` | Previous / next diagnostic |
| `<F5>`, `<leader>db` | Debug: continue, toggle breakpoint |

**When you forget a key**

| | |
|---|---|
| `<leader>fk` | Search *every* mapping, with descriptions |
| `<leader>fh` | Search the help |
| `g?` | Context-sensitive help inside diffview and neo-tree |

**When something is stale**

| | |
|---|---|
| `:lsp restart` | Reload the language server, e.g. after installing packages |
| `:checktime` | Re-read files changed outside nvim |
| `:checkhealth vim.lsp` | What the servers are doing (the old `:LspInfo`) |

## Working in a project

How the editor is laid out and how to move around it.

### Opening a project, IDE style

```sh
cd ~/src/myproject
nvim .
```

That gives you a 32-column file tree on the left and an empty editor window on
the right, cursor in the tree. `<cr>` on a file opens it in the editor window.
No extra command to run — neo-tree takes over directory arguments, which is
what `hijack_netrw_behavior = "open_default"` in `init.lua` is doing.

| Key | Does |
|---|---|
| `<leader>tt` | Toggle the tree |
| `<leader>tf` | Reveal the current file in the tree |
| `<leader>tg` | Git status as a tree (floating) |
| `<leader>tb` | Open buffers, in a right-hand split |

Inside the tree: `<cr>` opens, `S` and `s` open in a horizontal/vertical split,
`t` in a new tab, `a` add, `d` delete, `r` rename, `c` copy, `m` move, `H`
toggles hidden files, `?` shows the full list.

The tree follows the buffer you are editing, so `<leader>tf` is mostly for when
you have wandered. Dotfiles are shown; gitignored files are not.

Opening a *file* rather than a directory (`nvim src/thing.py`) deliberately
does **not** open the tree — otherwise every quick one-file edit from the shell
would ambush you with a sidebar. Use `<leader>tt` when you want it.

The rest of the IDE reflexes map onto what was already here:

| PyCharm | Here |
|---|---|
| Project pane | `nvim .`, or `<leader>tt` |
| Search Everywhere / Go to File | `<leader>ff` (fzf-lua) |
| Find in Path | `<leader>fg` |
| Go to Symbol | `<leader>fs`, `<leader>fS` for the workspace |
| Go to Declaration / Usages | `gd`, `gr` |
| Compare with Branch | `<leader>gc` (see above) |
| Debug | `<F5>`, `<leader>db` |

### Buffers, windows and tab pages

Coming from an IDE, the first instinct is to look for tabs inside a split.
There are none, and there cannot be: Nvim's model is arranged the other way
round.

- A **buffer** is a loaded file. The list is **global** — it is not owned by
  any window.
- A **window** is a viewport showing one buffer. Splitting does not duplicate
  anything; it just adds another viewport.
- A **tab page** is a whole-screen collection of windows. `:help tabpage` puts
  it plainly: "A tabpage holds one or more windows." So a tab contains splits,
  never the reverse. Vim tab pages are closer to workspaces than to editor tabs.

This is why there is no per-split tab bar: there is no per-window list of files
for one to display. The options confirm it — `'tabline'` is documented as
`global`, while `'winbar'` is `global or local to window`. A per-split bar is
therefore possible to *draw*, but nothing populates it, because the data it
would show does not exist.

What to reach for instead:

| Want | Use |
|---|---|
| Jump to an open file | `<leader>fb` |
| Flip to the file you were just in | `<C-^>` |
| Cycle open files | `:bnext` / `:bprev` |
| See what is open | `:ls` |
| Know which file is in which split | put `%f` in `'winbar'` |

The idiom is that splits are transient views and *buffers* are your tabs. You
switch the focused split to a different file rather than collecting tabs in it.

If you later decide you do want a visible strip of open files, the options are a
global bufferline across the top (not per-split), or per-tab-page buffer scoping
via scope.nvim or three.nvim, which turns tab pages into per-project workspaces.
Check the commit dates before adopting either: the usual bufferline pick,
bufferline.nvim, was last touched in January 2025 and has no `winbar` support at
all, so it could not be made per-split even in principle.

#### Naming a buffer

There is no alias concept. A buffer has a number and a name, and the name *is*
its path — so `:file {name}` does not label a buffer, it **renames the file it
will be written to**.

```vim
:file MY-ALIAS     " sets the current file name to MY-ALIAS
```

`:help :file` says it outright: "Sets the current file name to {name}. If the
buffer did have a name, that name becomes the |alternate-file| name." What it
does not spell out is where your next `:w` goes. Tested, on a buffer opened
from `real.py`:

```
:file ALIAS  →  :w  →  ls
ALIAS      contains your edits
real.py    still contains the original
```

No error, no warning, and the original file looks untouched — which is the
worst shape a mistake can take. Do not use `:file` on a buffer you are editing.
`:0file` removes a name; `:saveas` is what you want if you genuinely mean
"write this somewhere else and follow it there".

Where `:file` **is** the right tool is buffers with no file behind them, where
there is nothing to clobber — a terminal, or a scratch buffer:

```vim
:terminal
:file term://build-log       " now :ls and the pickers show a useful name
```

If what you want is a *display* label with the filename left alone, keep it in
a buffer-local variable and render that instead. Verified working:

```lua
vim.api.nvim_create_user_command("Alias", function(o)
  vim.b.alias = (o.args ~= "" and o.args) or nil
  vim.cmd("redrawstatus | redrawtabline")
end, { nargs = "?", desc = "Label this buffer (display only)" })

-- Anywhere that takes a statusline expression — winbar, statusline, lualine:
--   %{get(b:,'alias',expand('%:t'))}
```

`:Alias API handlers` then shows that label, `:Alias` with no argument clears it,
and `bufname()` never changes — so `:w` still goes exactly where it should.

#### `<leader>fb` is not native

It is fzf-lua, so `:help` has nothing under that name. The relevant docs:

```vim
:help fzf-lua                     " the plugin ships vimdoc
:help fzf-lua-buffers-and-files   " the buffer/file pickers specifically
:help fzf-lua-commands            " every :FzfLua picker
```

The native equivalents, all in `windows.txt`, are worth knowing because they
work in any vim you ever sit down at:

```vim
:help :ls        " list buffers
:help :buffer    " :b <partial-name> jumps, with completion
:help CTRL-^     " alternate buffer (in editing.txt)
:help :bnext
```

`:ls` then `:b <number>` is the zero-plugin version of the buffer picker. `:b`
takes a partial name too, so `:b conf<Tab>` usually gets there in fewer
keystrokes than the picker does.

### Splits

New splits go inside the current window by default, which is why a fourth
`:split` in a three-way layout carves up one column instead of spanning the
screen. The fix is native — no plugin:

```vim
:botright split     " full-width, at the bottom of everything
:topleft split      " full-width, at the top
:botright vsplit    " full-height, far right
:topleft vsplit     " full-height, far left
```

`aboveleft` and `belowright` are the relative counterparts, and are what plain
`:split` and `:vsplit` effectively do.

**Splitting that new window again is just a plain split.** The modifier applies
only to the command it prefixes, and after `:botright split` the cursor is
already in the new window — so `:vsplit` there divides the bottom band and
leaves the row above untouched:

```
3 vsplits             row[ leaf, leaf, leaf ]
+ :botright split     col[ row[ leaf, leaf, leaf ], leaf ]
+ plain :vsplit       col[ row[ leaf, leaf, leaf ], row[ leaf, leaf ] ]
+ plain :vsplit       col[ row[ leaf, leaf, leaf ], row[ leaf, leaf, leaf ] ]
```

Reach for `:topleft`/`:botright` again only when you want the new window to span
the whole editor; that is what would pull it back out of the bottom band.

#### Re-parenting a window: `<C-w>` capitals

A window that already exists can be promoted to an edge with `<C-w>` plus a
**capital** direction. The help spells out the relationship:

> `CTRL-W J`  Move the current window to be at the very bottom, using the full
> width of the screen. This works like `:botright split`, except it is applied
> to the current window and no new window is created.

So `H J K L` are the `:topleft`/`:botright` modifiers applied to an existing
window. They are the only native way to re-parent a window, and they are what
WinShift.nvim generalises.

**This is the fix when the file tree steals your full-width bottom window.**
Neo-tree's sidebar is itself a root-level full-height split, the same class of
operation as `:botright split`. Both want to be the outer container and the
last one to run wins — so toggling the tree off and on re-wraps everything
around the tree:

```
1. tree + editor        row[ TREE, editor ]
2. :botright split      col[ row[ TREE, editor ], bottom ]
3. Neotree close        col[ editor, bottom ]
4. Neotree show         row[ TREE, col[ editor, bottom ] ]   <- bottom no longer full width
5. <C-w>J in bottom     col[ row[ TREE, editor ], bottom ]   <- fixed
```

You choose which one is outer:

- `<C-w>J` with the cursor in the bottom window — bottom spans the full width,
  the tree is confined to the row above it.
- `<C-w>H` with the cursor in the tree — the tree spans the full height and the
  bottom window is confined to the right of it.

Verified by reading `winlayout()` on nvim 0.12 with three side-by-side windows:

```
3 vsplits:             row[ leaf, leaf, leaf ]
after :split           row[ col[ leaf, leaf ], leaf, leaf ]   <- nested
after :botright split  col[ row[ leaf, leaf, leaf ], leaf ]   <- root level
```

You do **not** need WinShift.nvim for this. That plugin solves the adjacent
problem — moving an existing window somewhere else in the layout — rather than
choosing where a new one lands. Worth noting it is by the same author as the
original diffview.nvim, so check its commit activity before adopting it.

### Floating windows

`:help` now opens in a centred float rather than a split, so it stops rearranging
your layout. `q` closes it as usual.

The autocmd behind it is worth knowing if you want to float something else: it
keys off `buftype == "help"`, not `filetype`. `:help` sets `buftype` itself,
whereas `filetype` depends on detection being enabled — which is exactly the
kind of thing that breaks under `-u` or a minimal config. Any window can be
converted the same way with `nvim_win_set_config(win, { relative = "editor", ... })`.

You already had floats without noticing: `K` (LSP hover) and the diagnostic
popups are both floating windows.

### netrw is still there

Neo-tree takes over directory arguments but does not disable netrw, so the
built-in explorer remains as a fallback: `:Lexplore` toggles it in a left split
and `:Explore` fills the window. Two things about it that are easy to get
wrong, both verified against the netrw shipped with 0.12:

- The count is a **percentage**, not columns. `:Lexplore 30` on a 200-column
  terminal gives you a 60-column split. For an absolute width, set
  `g:netrw_winsize = -30`.
- `g:netrw_liststyle = 3` is what turns the listing into a tree;
  `g:netrw_browse_split = 4` makes `<cr>` open the file in the previous window
  rather than replacing the explorer.

## Code navigation

Nvim 0.11+ binds most of the LSP verbs globally, before any config:

| Key | Does |
|---|---|
| `grr` | References |
| `gri` | Implementation |
| `grt` | Type definition |
| `grn` | Rename |
| `gra` | Code action |
| `gO` | Document symbols |
| `<C-s>` (insert) | Signature help |

This config adds the more vim-flavoured aliases on top: `gd` definition, `gD`
declaration, `gr` references, `gi` implementation, `K` hover, `<leader>rn`
rename, `<leader>ca` code action, `[d`/`]d` diagnostics.

Plus two that nvim does not bind and PyCharm users miss:

| Key | Does |
|---|---|
| `<leader>ci` | Incoming calls (Call Hierarchy) |
| `<leader>co` | Outgoing calls |
| `<C-LeftMouse>` | Ctrl-click to jump to definition |
| `<leader>fk` | Search every keymap (the "what was that key" picker) |
| `<leader>fj` | Jumplist picker |
| `<leader>fh` | Help tag search |

### Finding a key you half-remember

`<leader>fk` opens every mapping in the editor, with its description, in an
fzf picker. It is the general-purpose equivalent of diffview's `g?`, and it is
not limited to one plugin. `<leader>fh` searches the help tags the same way.

Diffview's `g?` is still the better view *inside* diffview, because it shows
only what is bound in that context. `<leader>fk` shows everything, which is
what you want when you cannot remember which plugin a key belonged to.

### Backtracking after a jump

| Key | Does |
|---|---|
| `<C-o>` | Back to where you jumped from |
| `<C-i>` | Forward again |
| `<C-t>` | Back up the tag stack (LSP jumps push onto it too) |
| `g;` / `g,` | Older / newer *edit* position, ignoring pure navigation |
| `` `` `` | The position before the latest jump |
| `<leader>fj` | The whole jumplist in a picker, to jump several steps back at once |

`<C-o>` is the one to internalise — it is PyCharm's Navigate Back, it is native
vim, needs no LSP, and works across files.

Two things that catch people out: the jumplist is **per window**, so splitting
and jumping in the new window starts a fresh history; and only *jumps* are
recorded, not every cursor move — `j` and `k` do not add entries, which is what
makes it useful. `:jumps` prints the raw list.

**Also worth knowing:** `<leader>fs` and `<leader>fS` cover symbol search in the
current file and across the workspace.

### Highlighting other occurrences of a symbol

Automatic: rest the cursor on a symbol for `updatetime` (250ms) and the other
occurrences light up, cleared as soon as you move. This is the *semantic*
version rather than a word match — the language server decides what counts as
the same symbol, so a local `x` will not light up an unrelated `x` in another
scope.

It only runs for servers advertising `textDocument/documentHighlight`, which
basedpyright and rust-analyzer both do. The `LspReference*` highlight groups
are defined by Nvim itself, so this needs nothing from the colorscheme.

For a plain textual match, and in buffers with no LSP, `*` and `#` still search
forward and backward for the word under the cursor, and `:set hlsearch` keeps
every match lit until `<Esc>`.

## Comparing revisions with diffview

The `nvim` answer to PyCharm's "Compare with Branch/Tag/Commit". A file panel
down the left, side-by-side diff on the right.

### Opening a comparison

```vim
:DiffviewOpen                      " working tree vs index
:DiffviewOpen main..feature        " branch vs branch
:DiffviewOpen v1.0..v2.0           " tag vs tag
:DiffviewOpen origin/main...HEAD   " merge base — what a PR would show
:DiffviewOpen HEAD~5               " the last five commits
:DiffviewOpen -- src/ tests/       " limit to paths
```

Leader mappings for the common entries:

| Key | Does |
|---|---|
| `<leader>gd` | Diff the working tree |
| `<leader>gc` | Prompts `:DiffviewOpen ` — type a revision, press enter |
| `<leader>gh` | History for the current file |
| `<leader>gH` | History for the whole repo |
| `<leader>gq` | Close the diffview tab |

`:DiffviewDiffDirs a b` compares two directories on disk with no repository
involved at all, which is handy for before/after trees.

### Moving around

These work in the diff windows *and* in the file panel:

| Key | Does |
|---|---|
| `]c` / `[c` | Next / previous change **within** the current file |
| `<tab>` / `<s-tab>` | Next / previous changed file |
| `[F` / `]F` | First / last changed file |
| `<leader>e` | Jump to the file panel |
| `<leader>b` | Show/hide the file panel |
| `gf` | Open the real file in the previous tabpage |
| `<C-w><C-f>` / `<C-w>gf` | Open the real file in a split / new tab |
| `g<C-x>` | Cycle layouts (side-by-side, unified, single) |
| `g?` | Help panel — `q` or `<esc>` closes it |

`]c` and `[c` are vim's own diff-mode motions rather than diffview's, which is
why they are not in its help panel. They work anyway because the side-by-side
windows are real diff windows. The unified (`diff1_inline`) layout is the
exception: that window has `diff=false`, so the plugin rebinds the same two
keys to walk its own cached hunks. Same keys everywhere, two mechanisms.

In the file panel specifically: `j`/`k` move, `<cr>`, `o` or `l` opens the
diff, `h` collapses a directory, `<c-b>`/`<c-f>` scroll.

### Showing unchanged lines

By default only the changed hunks are visible and everything else is folded
away. What makes this confusing is that there are really only two settings, but
one of them shows up at three different scopes:

- **`foldlevel`** — whether unchanged regions are folded at all. Adjustable for
  the window in front of you, for this nvim session, or permanently.
- **`diffopt.context`** — a different thing entirely: how many unchanged lines
  pad each hunk before folding begins.

**Right now, in a diff window: `zR`.** Opens every fold, showing the whole
file. `zM` collapses them again. The plugin mirrors fold commands across both
panes — `za zA ze zE zo zc zO zC zr zm zR zM zv zx zX zn zN` are all
replicated — because diffview uses `foldmethod=manual`, and vim only
auto-syncs folds between diff windows when `foldmethod=diff`.

Careful in the **file panel**: there the same `zR`/`zM` expand and collapse the
*directory tree*, not the diff. Same keys, different object.

**Just for this nvim session: mutate the live config.**

```vim
:lua require("diffview.config").get_config().view.foldlevel = 99
```

`get_config()` hands back the actual config table rather than a copy, so
assigning into it changes the setting in place. The value is read each time a
file entry is opened into a window, so it takes effect on the **next** file you
open — press `<tab>`, or reopen the view. Windows already on screen keep the
folds they were given; `zR` those. Set it back with `= 0`.

Do this with a diffview already open, or at least after opening one once. If
the plugin has not been configured yet, `get_config()` calls `setup()` with no
arguments to bootstrap itself, which lands you in the defaults-only trap below.

> **Do not use `setup()` for this.** The obvious-looking version is wrong:
>
> ```vim
> " WRONG — silently discards the rest of your config
> :lua require("diffview").setup({ view = { foldlevel = 99 } })
> ```
>
> `config.setup()` rebuilds the whole config from scratch on every call:
>
> ```lua
> M._config = vim.tbl_deep_extend("force", utils.tbl_deep_clone(M.defaults), user_config)
> ```
>
> Passing it a partial table therefore resets everything *not* in that table
> back to plugin defaults — `enhanced_diff_hl`, the `diff2_horizontal` and
> `diff3_horizontal` layouts, all of it. You get your foldlevel and quietly
> lose the rest, with no error to tell you.

If you want to flip it back and forth, a session-only mapping:

```vim
:lua vim.keymap.set("n", "<leader>gz", function() local v = require("diffview.config").get_config().view v.foldlevel = v.foldlevel == 0 and 99 or 0 vim.notify("diffview foldlevel = " .. v.foldlevel) end)
```

**Permanently: `view.foldlevel`.** Defaults to `0`, which is what collapses
unchanged regions. Set it to `99` and files open fully expanded, which is what
PyCharm does:

```lua
opts = {
  view = {
    foldlevel = 99,
    default = { layout = "diff2_horizontal" },
  },
},
```

This one is fork-only. The docs describe the default as "same behaviour as
upstream sindrets/diffview.nvim", so the knob does not exist in the plugin most
guides point at.

**Separately: `diffopt.context`,** how many unchanged lines show *around* each
hunk before folding starts. Vim's default is 6.

```lua
opts = {
  -- Applied only while diffview is open; your global diffopt is restored
  -- on close. Also accepts algorithm, linematch, indent_heuristic,
  -- iwhite, iwhiteall, iwhiteeol, iblank, icase.
  diffopt = { context = 12 },
},
```

Note that `foldlevel = 99` makes `context` moot — with nothing folded there is
no fold boundary for it to pad. Pick one: fully expanded, or folded with a
comfortable amount of context.

### Side-by-side diffs in the shell

Helix has no plugin system, so for `hx` and for the plain shell the equivalent
is delta, wired in as git's pager:

```sh
git diff main..feature      # two columns; n and N jump between files
git log -p                  # same treatment
git add -p                  # delta renders the interactive hunks too
```

`n`/`N` come from `delta.navigate`. They are implemented with `less`'s search,
which is why the Dockerfile pins `DELTA_PAGER=less` — delta otherwise honours
`$PAGER`, and with `moor` there the navigation silently stops working.

Side-by-side is on by default and is cramped in a narrow tmux pane. For one
invocation:

```sh
git -c delta.side-by-side=false diff main..feature
```

All the delta settings live in `/etc/gitconfig` rather than your global config,
because `~/.config/git` is a volume that would mask anything written at build
time. `git config --global` still overrides any of them, since global beats
system.

## Terminal setup (iTerm2)

### Glyphs showing as boxes

The icons are Nerd Font characters. The font has to be installed **on the Mac**,
not in the container — iTerm2 is what draws them, and it only knows about fonts
on the host.

```sh
brew install --cask font-jetbrains-mono-nerd-font
```

No separate tap; the font casks moved into the main Homebrew cask repo. Then
iTerm2 → Settings → Profiles → Text → Font, and pick **JetBrainsMono Nerd
Font**. Restart the pane or reattach tmux.

If you would rather keep your current font for code, iTerm2 can use a second
font just for the glyphs: same panel, tick **Use a different font for
non-ASCII text** and set the non-ASCII font to the Nerd Font. Per iTerm2's
docs that font is used "for all code points greater than or equal to 128",
which is exactly where the glyphs live.

The alternative is to use no glyphs at all: drop `nvim-tree/nvim-web-devicons`
from the neo-tree spec and set plain-text icons under
`default_component_configs.icon`, and override diffview's `icons` and `signs`
tables the same way. That is more config to carry than installing a font.

### Mouse support

It works through the whole stack — iTerm2 → container → tmux → nvim →
neo-tree — and both halves are already switched on: `mouse = "a"` in
`init.lua` and `set -g mouse on` in `tmux.conf`.

| Action | Works |
|---|---|
| Click a split to focus it | yes, nvim and tmux both |
| Drag a split separator to resize | yes |
| Drag a tmux pane border to resize | yes — tmux keeps events on its own borders |
| Scroll wheel in a buffer | yes |
| Double-click a file in neo-tree | yes, `<2-LeftMouse>` is bound to `open` |
| Ctrl-click to jump to a definition | yes, now mapped (see below) |

The layering question resolves itself: tmux forwards mouse events to whichever
application has asked for mouse reporting, so nvim gets them. Events on tmux's
own chrome — pane borders, status line — stay with tmux. Adding tmux panes
alongside nvim splits does not create a conflict.

**The one thing that changes.** With mouse reporting on, dragging selects text
*inside nvim* rather than making an iTerm2 selection, so Cmd-C no longer copies
what you dragged. Two ways out:

- Hold **Option** while dragging. Per iTerm2's docs: "Alt/Option: Mouse
  reporting will be disabled. If you're using vim and you can't make a
  selection, try holding down the alt key." That gives you the terminal's own
  selection back.
- Or just select in nvim and press `y`. OSC 52 is configured in all three of
  helix, nvim and tmux, so the yank reaches the Mac clipboard anyway. This is
  usually the better path — it survives split boundaries and does not pick up
  line numbers or the tree.

## Python environments and the language server

### Finding your `.venv`

Automatic. basedpyright's documented search order is:

1. `venv` + `venvPath` (least recommended)
2. `python.pythonPath`
3. **`.venv` at the project root** — where `uv venv` puts it
4. system Python

So a plain `uv venv` in the repo needs no configuration at all.

The one thing to get right is what counts as "project root": that is the LSP
root, which nvim-lspconfig derives from the first of these it finds —
`pyrightconfig.json`, `pyproject.toml`, `setup.py`, `setup.cfg`,
`requirements.txt`, `Pipfile`, `.git`. Your `.venv` has to sit beside one of
those. In a monorepo where the `.git` is several levels above the Python
package, the root can land higher than you expect and the venv is missed.

The escape hatch is a buffer-local command that nvim-lspconfig registers:

```vim
:LspPyrightSetPythonPath /path/to/.venv/bin/python
:LspPyrightOrganizeImports
```

Do **not** reach for `venvPath`/`venv` in a config file. basedpyright's own docs
call them discouraged, because they make pyright guess import paths from
directory layout instead of asking the interpreter for its real `sys.path`.

### After installing dependencies: restart the server

Newly installed packages do not appear on their own, and the reason is specific
to this container. Nvim's docs say `workspace/didChangeWatchedFiles` is enabled
by default **"except on Linux"**. So the server is never told that files
appeared. Add pyright resolving `sys.path` once at startup and caching import
resolution, and a fresh `uv pip install` stays invisible.

```vim
:lsp restart                 " every client on this buffer
:lsp restart basedpyright    " just the one
```

Definitely required if you created the venv *after* starting nvim — basedpyright
will have bound to the system Python.

Ruff needs nothing; it does not resolve imports against site-packages.

### `:lsp` versus `:Lsp*`

Nvim 0.12 ships a core `:lsp` command — `:lsp enable`, `:lsp disable`,
`:lsp restart`, `:lsp stop`. Use it.

Most guides on the internet still say `:LspRestart` and `:LspInfo`. Those come
from nvim-lspconfig, and **you will not have them**, because
`plugin/lspconfig.lua` opens with:

```lua
if vim.fn.exists(':lsp') == 2 then
  return
end
```

The plugin deliberately stands down once core provides the functionality. What
you still get from it are the per-server commands defined in `lsp/*.lua`, which
load off the runtimepath rather than from `plugin/` — hence
`:LspPyrightSetPythonPath` and `:LspPyrightOrganizeImports` existing while
`:LspRestart` does not. For the old `:LspInfo`, use `:checkhealth vim.lsp`,
which is all it was ever an alias for.

## Files changed outside nvim

Claude Code editing a file you have open is the common case. Nvim mostly copes,
with two gaps worth knowing.

`autoread` is on by default, so a buffer with no unsaved changes is silently
reloaded from disk. But nvim does not poll — it only *checks* at certain
moments, and sitting still inside a buffer is not one of them.

`init.lua` now nudges it. A `:checktime` runs on `FocusGained`, `BufEnter`,
`CursorHold`, `CursorHoldI` and `TermClose`, and a `FileChangedShellPost`
autocmd prints which file was reloaded, so a buffer changing underneath you is
never silent:

```
Reloaded from disk: watched.py
```

`CursorHold` fires after `updatetime` (250ms) of inactivity, so a file changed
while you sit in it comes back almost immediately. `:checktime` by hand still
works if you want to force one.

Two guards in that autocmd worth knowing about, since both are failure modes
rather than taste: `:checktime` is rejected while the command line is open, and
it can knock you out of terminal mode — so it skips cmdline mode and terminal
buffers. It uses `FileChangedShellPost` rather than `FileChangedShell` because
defining the latter *replaces* nvim's own handling of the change instead of
adding to it, which would disable the reload it is meant to announce.

Two consequences that are easy to misread:

- **The language server does not find out either.** File watching is off on
  Linux (see above), so until the buffer reloads, the server still holds nvim's
  copy. Diagnostics can point at lines that no longer exist. Reloading the
  buffer sends `didChange` and fixes both at once.
- **If you also have unsaved changes, nothing reloads silently.** You get
  `W12: File "..." has changed and the buffer was changed in Vim as well` and
  have to pick a side. Verified: with a local edit pending, an external write
  leaves your version in the buffer and prompts rather than clobbering it.
  `:e!` takes the disk version and discards yours.

## Which tool for which job

| Want | Use |
|---|---|
| Review a whole branch, file by file, keyboard-driven | `nvim` + `:DiffviewOpen` |
| Glance at a diff without leaving the shell | `git diff` (delta) |
| Trace when a line changed | `:DiffviewFileHistory %` |
| Compare two directories, no git involved | `:DiffviewDiffDirs a b` |
| Step through a debugger | `nvim` — the reason it is installed |
| Everything else, quickly | `hx` |

## Troubleshooting

Symptoms first: each entry says what you are seeing before it says why.

### A mapping does the *native* vim thing instead

Symptom: `<C-w><C-f>` splits and tries to open a file named after the word
under the cursor. `<C-w>gf` does the same in a new tab. `g<C-x>` does nothing
at all.

Those are exactly the built-in `CTRL-W CTRL-F` and `CTRL-W gf` commands, and
`g` followed by an unrecognised key. Getting the built-in behaviour means
diffview's mapping never matched — and the usual reason is `timeoutlen`.

Every one of those sequences starts with a key that is *already* a built-in
prefix (`<C-w>`, `g`). When you press it, nvim waits `timeoutlen` milliseconds
for the rest of a mapping. Take longer than that and it gives up on the
mapping, hands `<C-w>` to the built-in window command, and your second key
completes *that* instead. Nothing reports the switch.

This config used to set `timeoutlen = 400`, which is short enough to lose the
race whenever you are hunting for an unfamiliar chord rather than typing it
from muscle memory. It is now nvim's default of `1000`. If you still hit it:

```vim
:set timeoutlen=1500                 " decisive test — retry the key
:verbose nmap <C-w><C-f>             " is diffview's mapping even registered?
```

If `:verbose nmap` names diffview, the binding is fine and the problem is
purely timing. It is also a general nvim trap, not a diffview one: any
`<leader>`-prefixed mapping is subject to the same race.

This is also why a key can work from the help panel but not when typed — that
route never makes you type the prefix sequence under a stopwatch.

### `g?` stops working

`g?` is a **buffer-local** mapping. The plugin binds it in the diff windows,
the file panel, the file-history panel and the option panel — but not in the
help panel itself, where `q` or `<esc>` closes.

So it stops the moment focus is in a buffer diffview does not own. The easy
ways to end up there are `gf`, `<C-w><C-f>`, `<C-w>gf` — all of which
deliberately take you to the *real* file — or simply switching tabpage.

- Diagnose: `:verbose map g?` shows what is bound and where it came from.
- Recover: `:DiffviewFocusFiles`, or `<leader>e` if you are still inside the
  view.

> **Watch out:** in an ordinary buffer `g?` is vim's ROT13 operator. It waits
> silently for a motion and then scrambles that text. Diffview's own buffers
> are read-only so you get `E21: Cannot make changes`, but the LOCAL side of a
> working-tree diff is your real, writable file. If `g?` "did nothing" and you
> then pressed a motion, check with `u` or `git diff` before blaming the
> plugin.

### `g<C-x>` does nothing in the file panel

Layout cycling is bound only in the diff windows, not the panel. In the
plugin's keymap table, `view` is built as
`vec_join(common_nav_keymaps, { <C-w>T, g<C-x> }, fold_cmds)` and is documented
as active "in the diff buffers, only when the current tabpage is a Diffview",
while `file_panel` is `vec_join(common_panel_keymaps, common_nav_keymaps, ...)`
— which does not include `g<C-x>`. Move into a diff window first.

### Seeing that a prefix is pending

Nvim shows partially typed commands via `'showcmd'`, which is on by default —
but it renders in the bottom-right of the command line, which is easy to miss
when a statusline plugin is drawing your attention elsewhere. To move it into
the statusline instead:

```lua
vim.o.showcmdloc = "statusline"   -- then add "%S" as a lualine component
```

lualine does not include `%S` in any default section, so it has to be added by
hand. Check what your nvim supports with `:help showcmdloc` before relying on
it.

For something louder, [which-key.nvim](https://github.com/folke/which-key.nvim)
pops up the list of keys that can follow a prefix. Its README states the delay
is "independent of `timeoutlen`", so you can pair a fast popup with a generous
timeout rather than trading one against the other. Worth knowing what it does
*not* promise: the README says nothing about whether it lets a mapping still
fire after you pause longer than `timeoutlen`, so treat it as an indicator, not
as a fix for the trap above. `timeoutlen` remains the actual fix.

### When a jump does nothing

`gri` (or `gd`, `grr`, …) landing you nowhere has two quite different causes,
and Nvim distinguishes them — it just says so quietly:

- **"No locations found"** — the server was asked and had no answer.
- **"method ... is not supported by any server activated for this buffer"** —
  the server does not implement that request at all.

The second is the likely one for `gri` in Python. "Go to implementation" assumes
an interface/implementation split that Python does not really have, so
basedpyright may not advertise the capability. Check it directly:

```vim
:lua =vim.lsp.get_clients({ bufnr = 0 })[1].server_capabilities.implementationProvider
```

`nil` or `false` means `gri` will never do anything in that buffer, and `grr`
(references) is what you actually want. rust-analyzer does implement it.

Both messages were easy to miss because Nvim prints them unhighlighted in the
message line. `init.lua` now routes `vim.notify` through `nvim_echo` so they are
coloured by level — blue for info, yellow for warnings, red for errors — and
still land in `:messages`. That is done by level rather than by matching the
message text, so a future Nvim that rewords a message cannot quietly turn it off.

### If the tree renders as boxes

Your terminal font has no Nerd Font glyphs. This is not specific to neo-tree —
diffview's defaults use the same characters, so if one looks wrong the other
already did. See [Glyphs showing as boxes](#glyphs-showing-as-boxes).

### The file tree stole my full-width bottom window

Toggling the tree off and on re-wraps the layout around it, because a sidebar
is itself a root-level split competing with your `:bo sp`. Put the cursor in the
bottom window and press `<C-w>J`. Mechanism under
[Re-parenting a window](#re-parenting-a-window-c-w-capitals).
