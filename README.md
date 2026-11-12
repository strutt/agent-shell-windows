# agent-shell-windows

Let an agent show you files beside its conversation in a dedicated window group
in Emacs.

## Prerequisites

- Emacs 29.1+
- [web-server](https://github.com/eschulte/emacs-web-server)
- [agent-shell](https://github.com/xenodium/agent-shell) with an agent that supports HTTP MCP

## Install

```elisp
(use-package agent-shell-windows
  :straight (:type git :host github :repo "strutt/agent-shell-windows")
  :demand t)
```

## How it works

I don't trust agents enough to give them routine access to my
credentials or my Emacs. (Emacs contains the keys to my kindgom). To
avoid using emacsclient Emacs starts a local web server on
http://host.docker.internal:8765/mcp The server listens for MCP
requests from the agent and actions the pre-approved lisp is run.

Containerised agents are best practice, other if you have administrator access,
then they do to. To connect to an agent shell running in Docker, set the
advertised URL in `.dir-locals.el`:

```elisp
((nil . ((agent-shell-windows-mcp-url
          . "http://host.docker.internal:8765/mcp"))))
```

### What it does

The agent can ask for up to 3 agent-shell-windows (grouped with the agent-shell
buffer itself).

The agent controls the files, the viewport and can highlight regions.

Ask it to show the code it's written or screenshots it's created, it's a nice
experience.

### Some useful functions

`agent-shell-windows-start` idempotently starts the server. Once the package is
loaded it's called for you in a hook around the `agent-shell` function. You can
stop the server with `agent-shell-windows-stop` to turn it off at any time.
