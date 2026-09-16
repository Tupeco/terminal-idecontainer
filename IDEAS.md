# Ideas

Things worth building here that are not built yet. One section each: what it
would do, and what it buys.

## `:Term` — never show one terminal buffer in two windows

Neovim sizes a terminal's pty to the **largest** window displaying that buffer,
across every tab — `terminal_check_size()` in `terminal.c` takes `MAX` over
`FOR_ALL_TAB_WINDOWS`, not the window you are in. So the moment the same
terminal is visible twice at different sizes, a full-screen program in the
smaller view is told it has more rows than it does, and draws the top of its
output into scrollback where the program itself cannot reach it. A pager looks
broken: the first screenful is missing and going to the top does not bring it
back. Measured — a 10-row `:bo` terminal that is also open fullscreen in another
tab reports `27 100` to `stty size`.

Nothing warns you, and the symptom points at the pager rather than at the
window, so this is worth removing by construction rather than remembering.

`:Term` would keep the invariant *one terminal buffer, at most one window*:

| Situation | `:Term` |
| --- | --- |
| terminal already visible in this tab | jump to that window |
| visible only in another tab | jump to that tab |
| not visible anywhere | `:botright split` a new terminal |
| `:Term!` | always a fresh terminal buffer, for when two shells is the point |

A cheaper version, if the command feels like too much machinery: a
`WinEnter`/`TabEnter` autocmd that notifies when a terminal buffer is displayed
in more than one window. It prevents nothing, but it turns a baffling pager into
a one-line message.

Either way the escape hatch stays the same — two shells means two terminal
buffers, not two views of one.
