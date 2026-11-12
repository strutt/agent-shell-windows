# agent-shell-window specification

## Purpose

`agent-shell-window` lets an agent guide the user around files in Emacs. Each window session belongs to one agent-shell buffer and has an associated display buffer, display window, and saved window configuration.

The package works through agent-shell and standard MCP. It is independent of Sia, Codex, and other agent providers. HTTP MCP support is required from the agent's adapter.

The package explains itself through MCP tool schemas, descriptions, and instructions about viewing files. It does not ship a separate usage skill. Review workflow belongs outside this package.

## Session and window lifetime

1. The user starts and stops a window session through `agent-shell-window-start` and `agent-shell-window-stop` for a particular agent-shell buffer.
2. Starting a session starts the shared Emacs HTTP server if needed. Further sessions reuse that server. Starting an already-active window session reuses its association.
3. The initial layout is a 50/50 split: agent-shell on the left, its associated file display on the right.
4. The display has a stable buffer name, such as `*agent-shell-window: <shell-buffer-name>*`, across file changes. Its owner must be clear from its name.
5. While the window session is active, file requests reuse the associated display window or recreate it if it has been closed. Closing the window or killing its display buffer leaves the window session active.
6. Stopping leaves the current layout unchanged. Further display requests are rejected until the user explicitly starts the window session again. MCP calls cannot reactivate it.
7. Stopping one window session leaves other sessions and the shared server available.
8. File requests preserve the user's selected window and keyboard focus.
9. If a session is hidden, retain its latest file request and show it when the user switches back. Incoming requests do not bring hidden sessions into view.

```text
active session + display(file) -> show file; recreate window if needed
stopped session + display(file) -> reject request
```

## Switching sessions

Support `agent-shell-switch-buffer` and `agent-shell-toggle` as the user's existing ways to move between sessions.

Save the outgoing window session's current Emacs window configuration before switching away. When either command brings a session with an active `agent-shell-window` into view, restore its saved configuration.

This restores the buffers, window sizes, and scrolling that the user left. The 50/50 split is the initial layout; saved configurations preserve later adjustments. Several sessions can keep their own layouts while the user switches between them in the same Emacs frame.

For `agent-shell-toggle`, restore the saved configuration when it brings the session into view. Toggling away restores the layout shown immediately before entering that session.

Switching to a session without an active viewer removes the outgoing session's file window from the visible layout.

Saved configurations belong to an Emacs frame. Switching back returns to that original frame. If it has been deleted, attach the session to the current frame and recreate its 50/50 layout.

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

## `show_file`

Every request must supply `file`, `highlights`, and `viewport`, including all range endpoints and `viewport.top_line`. There are no omitted-field defaults.

```json
{
  "file": "src/main.el",
  "highlights": [
    {"start": [10, 0], "end": [14, 0]},
    {"start": [28, 4], "end": [28, 18]}
  ],
  "viewport": {"top_line": 24}
}
```

1. Resolve `file` against the session's captured working directory and enforce its boundary on the server.
2. Highlight positions are `[line, column]` in the displayed live text. Lines start at 1; columns start at 0. Columns count Emacs text characters; a tab counts as one. End positions are exclusive.
3. Support several highlight ranges, including partial lines. Highlights belong to the session's view.
4. Every request replaces the current highlight set. Use `highlights: []` explicitly to clear it.
5. `viewport.top_line` sets the first visible line independently of the highlights. Highlighted ranges may be outside the viewport.
6. The same requirements apply when requesting the file already displayed.

## `get_view`

This operation takes no tool arguments. When the active view is visible, report its actual current file, mode, visible text and line range, cursor position, and highlights. Read live buffer text, including unsaved edits, after either the agent or the user navigates.

For other states, report `hidden`, `closed`, or `stopped`. The operation does not recreate or reveal the view. Return visible text only for an active, visible view within the allowed directory.

## Request failures

Keep handling lightweight. Invalid input may raise an ordinary Emacs error. Catch errors at the HTTP/MCP request boundary and return an error while keeping Emacs and the shared HTTP server running.

Exhaustive validation and transactional rollback are not required. Display changes made before a request fails may remain.

The active-session and resolved-path checks remain mandatory before displaying or reading files. Request failures must preserve unsaved edits and leave the server able to handle subsequent requests.
