# Tips

Things in here that are easy to get wrong or hard to discover. The README
covers what is installed and why; this covers how to actually drive it.

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

### Troubleshooting keys

#### `g?` stops working

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

#### A mapping does the *native* vim thing instead

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

#### `g<C-x>` does nothing in the file panel

Layout cycling is bound only in the diff windows, not the panel. In the
plugin's keymap table, `view` is built as
`vec_join(common_nav_keymaps, { <C-w>T, g<C-x> }, fold_cmds)` and is documented
as active "in the diff buffers, only when the current tabpage is a Diffview",
while `file_panel` is `vec_join(common_panel_keymaps, common_nav_keymaps, ...)`
— which does not include `g<C-x>`. Move into a diff window first.

#### Seeing that a prefix is pending

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

## Opening a project, IDE style

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

### If the tree renders as boxes

The folder glyphs are Nerd Font characters, and `nvim-web-devicons` adds more
of them for individual filetypes. If your terminal font has no glyphs you will
get tofu boxes. Either point the terminal at a Nerd Font, or drop the
`nvim-tree/nvim-web-devicons` dependency and set plain-text icons under
`default_component_configs.icon` in the neo-tree spec.

Note this is not specific to neo-tree — diffview's default config uses the same
kind of glyph for its folder icons, so if one looks wrong the other already did.

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

## Side-by-side diffs in the shell

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

## Which tool for which job

| Want | Use |
|---|---|
| Review a whole branch, file by file, keyboard-driven | `nvim` + `:DiffviewOpen` |
| Glance at a diff without leaving the shell | `git diff` (delta) |
| Trace when a line changed | `:DiffviewFileHistory %` |
| Compare two directories, no git involved | `:DiffviewDiffDirs a b` |
| Step through a debugger | `nvim` — the reason it is installed |
| Everything else, quickly | `hx` |
