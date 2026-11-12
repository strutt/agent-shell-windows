# agent-shell-windows specification

## Purpose

`agent-shell-windows` lets an agent guide the user around files in Emacs. Each window session belongs to one agent-shell buffer and has up to three numbered file panes and a saved window configuration. Each pane uses an ordinary file buffer, a dedicated window, and window-specific highlights.

The package works through agent-shell and standard MCP. It is independent of Sia, Codex, and other agent providers. HTTP MCP support is required from the agent's adapter.

The package explains itself through MCP tool schemas, descriptions, and instructions about viewing files. It does not ship a separate usage skill. Review workflow belongs outside this package.

## Session and window lifetime

1. The user starts and stops a window session through `agent-shell-windows-start` and `agent-shell-windows-stop` for a particular agent-shell buffer.
2. Starting a session starts the shared Emacs HTTP server if needed. Further sessions reuse that server. Starting an already-active window session reuses its association.
3. The initial layout is an equal split between chat and one file pane. Use `split-window-sensibly` to choose side by side or stacked, falling back to a split that respects minimum window sizes.
4. Pane IDs are 1, 2, and 3 within the existing session routing ID. Each window has a header showing the package name, pane number, and owning agent’s icon. File buffers keep their ordinary names and modes.
5. While the window session is active, file requests reuse the associated display window or recreate it if it has been closed. Closing the window or killing its display buffer leaves the window session active.
6. Stopping leaves the current layout unchanged. Further display requests are rejected until the user explicitly starts the window session again. MCP calls cannot reactivate it.
7. Stopping one window session leaves other sessions and the shared server available.
8. File requests preserve the user's selected window and keyboard focus.
9. If a session is hidden, retain its latest complete display request and show it when the user switches back. Incoming requests do not bring hidden sessions into view.

```text
active session + display(file) -> show file; recreate window if needed
stopped session + display(file) -> reject request
```

## Switching sessions

Support `agent-shell-switch-buffer` and `agent-shell-toggle` as the user's existing ways to move between sessions.

Save the outgoing window session's current Emacs window configuration before switching away. When either command brings a session with an active `agent-shell-windows` into view, restore its saved configuration.

This restores the buffers, window sizes, and scrolling that the user left. The 50/50 split is the initial layout; saved configurations preserve later adjustments. Several sessions can keep their own layouts while the user switches between them in the same Emacs frame.

For `agent-shell-toggle`, restore the saved configuration when it brings the session into view. Toggling away restores the layout shown immediately before entering that session.

Switching to a session without an active viewer removes the outgoing session's file window from the visible layout.

Saved configurations belong to an Emacs frame. Switching back returns to that original frame. If it has been deleted, attach the session to the current frame and recreate its automatic layout.

## Files and modes

Display ordinary files through Emacs' normal file handling. File associations, including extensions, determine the mode. The user controls those associations and the presentation.

Each session has its own named view, scrolling, and highlights. Views of the same file share its live text and unsaved edits.

When a requested file has changed on disk and its Emacs buffer has no unsaved edits, reload it automatically. If there are unsaved edits, preserve and display the live buffer, including when the disk contents have also changed.

The agent can use Git to write a focused diff into a file, then display that file. Markdown notes or review comments can likewise live in a normal file and use the same display operation.

The MCP has no built-in review, comment, note, diff, or hunk model. File creation and editing use the agent's normal tools.

## File access

Capture the associated agent-shell working directory when the window session starts. It stays fixed while that session is active; restarting can capture a new directory.

Requests use paths relative to that directory. Absolute paths are rejected.

The Emacs server enforces the directory boundary for both file display and current-view requests, resolving symlinks before checking access. Reading a manually navigated view must also respect this boundary.

## Automatic connection and routing

1. Use a shared HTTP MCP endpoint in Emacs.
2. Create a routing ID associated with each agent-shell buffer, independently of provider-specific session IDs.
3. Supply the server address and routing ID automatically through agent-shell's MCP connection settings, preserving existing MCP entries. The MCP client carries the ID in an HTTP header.
4. Route incoming calls to the matching agent-shell buffer and window session. The agent's tool arguments describe the file operation rather than choosing a session.
5. The user should never need to paste an endpoint URL or routing ID into the conversation.
6. Registering the MCP connection and activating the window session are separate. The user's Emacs controls determine whether display requests are accepted.
7. Ensure the shared server is running when preparing the MCP connection, independently of viewer activation.

The advertised MCP URL defaults to `http://localhost:8765/mcp`. It is an Emacs variable configurable through `.dir-locals.el`. Docker or remote setups explicitly configure a reachable URL and the necessary networking. Agent-shell passes the chosen URL into each agent connection automatically.

Register the MCP connection when the agent connection starts or reconnects. An existing connection may need reconnecting to receive changed MCP settings; refreshing them during a running connection depends on the adapter.

## `show_files`

One call describes the entire display. Supply a `panes` array of one to
three complete entries in order, with pane IDs 1 through the array length.
The existing routing header identifies the session; tool arguments cannot
choose another session. There is no separate layout or pane-count tool.
Omitted panes close without killing their file buffers or losing edits.

```json
{
  "panes": [
    {
      "pane": 1,
      "file": "src/main.el",
      "highlights": [{"start": [10, 0], "end": [14, 0]}],
      "viewport": {"top_line": 8}
    },
    {
      "pane": 2,
      "file": "tests/main-test.el",
      "highlights": [],
      "viewport": {"top_line": 1}
    }
  ]
}
```

Each entry requires `pane`, `file`, `highlights`, and `viewport.top_line`.
Validate all entries and resolved paths before changing the display.
Paths stay within the session's captured working directory.

Highlights use `[line, column]` with lines starting at 1, columns at 0,
and exclusive ends. Columns count characters; a tab counts as one.
Every entry replaces that pane's highlight set; `[]` clears highlights.
Viewport positioning is independent of highlights. All panes show live
text and preserve unsaved edits, including multiple views of one file.

The server alone chooses the layout:

- One file pane: the standard Emacs split between chat and the file area.
- Two file panes: preserve the initial split and subdivide the file area
  with the standard Emacs heuristic.
- Three file panes: split evenly into four quadrants, with chat top left,
  pane 1 top right, pane 2 bottom left, and pane 3 bottom right.

Preserve user resizing when the pane count stays the same and all panes
exist. On a count change or missing pane, arrange the required windows.
If minimum sizes prevent a requested layout, report an error and restore
the previous count and window configuration. File panes are strongly
dedicated except while the server replaces their displayed buffers.

## `get_view`

This operation takes no arguments and returns every configured pane in a
`panes` array. Each entry identifies its pane and reports its actual current
file, mode, visible text and range, cursor position, unsaved status, and
highlights. Read live text after either the agent or user navigates.

Report `empty`, `hidden`, `closed`, or `stopped` as appropriate per pane.
The operation does not recreate or reveal a view. Return visible text only
for an active, visible pane within the allowed directory.

## Request failures

Keep handling lightweight. Invalid input may raise an ordinary Emacs error. Catch errors at the HTTP/MCP request boundary and return an error while keeping Emacs and the shared HTTP server running.

Exhaustive validation and transactional rollback are not required. Display changes made before a request fails may remain.

The active-session and resolved-path checks remain mandatory before displaying or reading files. Request failures must preserve unsaved edits and leave the server able to handle subsequent requests.
