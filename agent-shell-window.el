;;; agent-shell-window.el --- Show files beside agent-shell -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.95.1") (web-server "0.1.2"))

;;; Commentary:

;; Add this directory to `load-path' and require agent-shell-window before
;; starting an agent connection.  MCP registration is automatic.  Use
;; `agent-shell-window-start' and `agent-shell-window-stop' in the shell
;; buffer to control whether its agent may display files.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup agent-shell-window nil
  "View files beside an agent-shell conversation."
  :group 'tools)

(defcustom agent-shell-window-mcp-url "http://localhost:8765/mcp"
  "MCP URL advertised to the agent.
Set this through directory-local variables when the agent needs a
different address, such as http://host.docker.internal:8765/mcp."
  :type 'string
  :group 'agent-shell-window)
(make-variable-buffer-local 'agent-shell-window-mcp-url)

(cl-defstruct (agent-shell-window--session
               (:constructor agent-shell-window--make-session))
              id shell root active frame window buffer request overlays configuration previous)

(defvar agent-shell-window--sessions (make-hash-table :test #'equal))
(defvar-local agent-shell-window--session nil)
(defvar agent-shell-prefer-viewport-interaction)

(add-to-list 'window-persistent-parameters '(agent-shell-window-session . t))

(declare-function agent-shell-window-http--ensure "agent-shell-window-http" ())
(declare-function agent-shell--current-shell "agent-shell" ())
(declare-function agent-shell-project-buffers "agent-shell" ())
(declare-function agent-shell-buffers "agent-shell" ())
(declare-function agent-shell-viewport--buffer "agent-shell-viewport" (&rest arguments))

(defun agent-shell-window--register ()
  "Return the current shell's routing association, creating it if needed."
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Choose an agent-shell buffer"))
  (unless agent-shell-window--session
    (let ((id (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert-file-contents-literally "/dev/urandom" nil nil 32)
                (secure-hash 'sha256 (current-buffer)))))
      (setq agent-shell-window--session
            (agent-shell-window--make-session :id id :shell (current-buffer)))
      (puthash id agent-shell-window--session agent-shell-window--sessions)
      (add-hook 'kill-buffer-hook #'agent-shell-window--unregister nil t)))
  agent-shell-window--session)

(defun agent-shell-window--unregister ()
  "Remove the current shell's routing association."
  (when agent-shell-window--session
    (mapc #'delete-overlay
          (agent-shell-window--session-overlays agent-shell-window--session))
    (remhash (agent-shell-window--session-id agent-shell-window--session)
             agent-shell-window--sessions)))

(defun agent-shell-window--ensure-server ()
  "Ensure the shared HTTP server is running."
  (require 'agent-shell-window-http)
  (agent-shell-window-http--ensure))

(defun agent-shell-window--mcp-servers (servers)
  "Append this shell's MCP connection to normalized SERVERS.
A failure here must not prevent the session from starting, so on
error the shell proceeds without file viewing."
  (condition-case err
      (progn
        (agent-shell-window--ensure-server)
        (let ((session (agent-shell-window--register)))
          (vconcat
           (cl-remove-if
            (lambda (server) (equal (alist-get 'name server) "agent-shell-window"))
            (append servers nil))
           (vector
            `((name . "agent-shell-window")
              (type . "http")
              (url . ,agent-shell-window-mcp-url)
              (headers . [((name . "X-Agent-Shell-Window-Session")
                           (value . ,(agent-shell-window--session-id session)))]))))))
    ((error quit)
     (display-warning
      'agent-shell-window
      (format "File viewing is unavailable for this session: %s"
              (error-message-string err)))
     servers)))

(with-eval-after-load 'agent-shell
  (advice-add 'agent-shell--mcp-servers :filter-return
              #'agent-shell-window--mcp-servers)
  (advice-add 'agent-shell-switch-buffer :around #'agent-shell-window--switch-buffer)
  (advice-add 'agent-shell--display-buffer :around #'agent-shell-window--display-buffer)
  (advice-add 'agent-shell-toggle :around #'agent-shell-window--toggle))

(defun agent-shell-window--read-shell ()
  "Read an agent-shell buffer, using the current one when appropriate."
  (if (derived-mode-p 'agent-shell-mode)
      (current-buffer)
    (get-buffer
     (completing-read
      "Agent shell: "
      (mapcar #'buffer-name
              (cl-remove-if-not
               (lambda (buffer)
                 (with-current-buffer buffer
                   (derived-mode-p 'agent-shell-mode)))
               (buffer-list)))
      nil t))))

(defun agent-shell-window--shell-window (session)
  "Return SESSION's visible shell window in its owning frame."
  (let ((frame (agent-shell-window--session-frame session)))
    (when (and (frame-live-p frame) (frame-visible-p frame))
      (get-buffer-window (agent-shell-window--session-shell session) frame))))

(defun agent-shell-window--display-window (session)
  "Find SESSION's display window, including after restoring a configuration."
  (when (frame-live-p (agent-shell-window--session-frame session))
    (let ((window
           (cl-find-if
            (lambda (window)
              (eq (window-parameter window 'agent-shell-window-session) session))
            (window-list (agent-shell-window--session-frame session) 'nomini))))
      (setf (agent-shell-window--session-window session) window)
      (when window
        (dolist (overlay (agent-shell-window--session-overlays session))
          (overlay-put overlay 'window window)))
      window)))

(defun agent-shell-window--buffer-session (buffer)
  "Return BUFFER's association, resolving an agent-shell viewport if needed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (or agent-shell-window--session
          (when-let ((shell (agent-shell--current-shell)))
            (buffer-local-value 'agent-shell-window--session shell))))))

(defun agent-shell-window--visible-session ()
  "Return the associated shell visible in the selected frame."
  (cl-find-if
   (lambda (session)
     (and (eq (agent-shell-window--session-frame session) (selected-frame))
          (agent-shell-window--shell-window session)))
   (hash-table-values agent-shell-window--sessions)))

(defun agent-shell-window--save (session)
  "Save an active, visible SESSION's current window configuration."
  (when (and session (agent-shell-window--session-active session)
             (agent-shell-window--shell-window session))
    (setf (agent-shell-window--session-configuration session)
          (current-window-configuration (agent-shell-window--session-frame session)))))

(defun agent-shell-window--refresh-view (session)
  "Reattach SESSION's highlights and apply its pending file request."
  (agent-shell-window--display-window session)
  (when-let ((view (agent-shell-window--session-buffer session)))
    (when (buffer-live-p view)
      (with-current-buffer view
        (rename-buffer (agent-shell-window--buffer-name session) t))))
  (when (and (agent-shell-window--session-active session)
             (agent-shell-window--session-request session))
    (condition-case err
        (agent-shell-window--show-file
         session (agent-shell-window--session-request session))
      ((error quit)
       ;; A request that can no longer be displayed must not keep
       ;; aborting every entry into the session.
       (setf (agent-shell-window--session-request session) nil)
       (message "agent-shell-window: dropped undisplayable view request (%s)"
                (error-message-string err))))))

(defun agent-shell-window--enter (session before outgoing)
  "Restore SESSION when leaving OUTGOING, with BEFORE as the prior layout."
  (unless (frame-live-p (agent-shell-window--session-frame session))
    (setf (agent-shell-window--session-frame session) (selected-frame)
          (agent-shell-window--session-configuration session) nil
          (agent-shell-window--session-previous session) nil))
  (let ((frame (agent-shell-window--session-frame session)))
    (when (and (not (eq session outgoing))
               (eq frame (window-configuration-frame before)))
      (setf (agent-shell-window--session-previous session) before))
    (unless (agent-shell-window--session-previous session)
      (setf (agent-shell-window--session-previous session)
            (current-window-configuration frame)))
    ;; A native switch may already have changed the caller's other frame.
    (unless (eq frame (window-configuration-frame before))
      (set-window-configuration before))
    (select-frame-set-input-focus frame)
    (if-let ((configuration (agent-shell-window--session-configuration session)))
        (set-window-configuration configuration)
      (agent-shell-window--layout session t))
    (agent-shell-window--refresh-view session)
    (agent-shell-window--shell-window session)))

(defun agent-shell-window--remove-display (session)
  "Remove SESSION's display window from the current layout."
  (when-let ((window (and session (agent-shell-window--display-window session))))
    (delete-window window)))

(defun agent-shell-window--switch-buffer (original &rest arguments)
  "Preserve session layouts around the native switch command ORIGINAL."
  (let ((before (current-window-configuration))
        (outgoing (agent-shell-window--visible-session)))
    (agent-shell-window--save outgoing)
    (let* ((buffer (apply original arguments))
           (incoming (agent-shell-window--buffer-session buffer)))
      (if (and incoming (agent-shell-window--session-active incoming))
          (agent-shell-window--enter incoming before outgoing)
        (when incoming
          (setf (agent-shell-window--session-previous incoming) before))
        (when outgoing
          (set-window-configuration before)
          (agent-shell-window--remove-display outgoing)
          (switch-to-buffer buffer)))
      buffer)))

(defun agent-shell-window--display-buffer (original buffer)
  "Display BUFFER through ORIGINAL or its saved window session."
  (let ((incoming (agent-shell-window--buffer-session buffer))
        (outgoing (agent-shell-window--visible-session))
        (before (current-window-configuration)))
    (agent-shell-window--save outgoing)
    (if (and incoming (agent-shell-window--session-active incoming))
        (agent-shell-window--enter incoming before outgoing)
      (when incoming
        (setf (agent-shell-window--session-previous incoming) before))
      (agent-shell-window--remove-display outgoing)
      (funcall original buffer))))

(defun agent-shell-window--hide (session)
  "Hide SESSION's pair and return to its previous layout."
  (agent-shell-window--save session)
  (let ((chat (agent-shell-window--shell-window session))
        (previous (agent-shell-window--session-previous session)))
    (agent-shell-window--remove-display session)
    (when (window-live-p chat) (quit-restore-window chat 'bury))
    (when (and previous (frame-live-p (window-configuration-frame previous)))
      (set-window-configuration previous)
      ;; Activation may have happened after the chat was already displayed.
      (when-let ((window (get-buffer-window (agent-shell-window--session-shell session))))
        (quit-restore-window window 'bury))
      (when-let ((restored (agent-shell-window--visible-session)))
        (agent-shell-window--refresh-view restored)))))

(defun agent-shell-window--toggle (original &rest arguments)
  "Toggle saved layouts while preserving ORIGINAL's shell selection rules."
  (let* ((buffer (if agent-shell-prefer-viewport-interaction
                     (agent-shell-viewport--buffer)
                   (or (agent-shell--current-shell)
                       (car (agent-shell-project-buffers))
                       (car (agent-shell-buffers)))))
         (session (agent-shell-window--buffer-session buffer)))
    (if (and session (agent-shell-window--session-active session))
        (if (agent-shell-window--shell-window session)
            (agent-shell-window--hide session)
          (let ((before (current-window-configuration))
                (outgoing (agent-shell-window--visible-session)))
            (agent-shell-window--save outgoing)
            (agent-shell-window--enter session before outgoing)))
      (apply original arguments))))

(defun agent-shell-window--buffer-name (session)
  "Return the display buffer name for SESSION."
  (format "*agent-shell-window: %s*"
          (buffer-name (agent-shell-window--session-shell session))))

(defun agent-shell-window--layout (session initial)
  "Show SESSION's pair, creating an INITIAL layout when requested."
  (with-selected-frame (agent-shell-window--session-frame session)
    (let* ((chat (or (agent-shell-window--shell-window session)
                     (selected-window)))
           (view (agent-shell-window--session-buffer session)))
      (when initial
        (setf (agent-shell-window--session-window session) nil)
        (set-window-parameter chat 'agent-shell-window-session nil)
        (set-window-dedicated-p chat nil)
        (set-window-buffer chat (agent-shell-window--session-shell session))
        (delete-other-windows chat))
      (unless (buffer-live-p view)
        (setq view (generate-new-buffer (agent-shell-window--buffer-name session)))
        (with-current-buffer view
          (setq default-directory (agent-shell-window--session-root session)))
        (setf (agent-shell-window--session-buffer session) view))
      (let ((window (or (agent-shell-window--display-window session)
                        (split-window chat nil 'right))))
        (set-window-parameter window 'agent-shell-window-session session)
        (set-window-dedicated-p window nil)
        (set-window-buffer window view)
        (setf (agent-shell-window--session-window session) window)
        (dolist (overlay (agent-shell-window--session-overlays session))
          (overlay-put overlay 'window window))
        window))))

;;;###autoload
(defun agent-shell-window-start (&optional shell)
  "Activate file viewing for SHELL, or the current agent-shell buffer."
  (interactive (list (agent-shell-window--read-shell)))
  (let ((before (current-window-configuration))
        (outgoing (agent-shell-window--visible-session)))
    (agent-shell-window--save outgoing)
    (with-current-buffer (or shell (current-buffer))
      (let* ((session (agent-shell-window--register))
             (initial (not (agent-shell-window--session-active session))))
        (agent-shell-window--ensure-server)
        (when initial
          (setf (agent-shell-window--session-root session)
                (file-name-as-directory (file-truename default-directory))
                (agent-shell-window--session-request session) nil
                (agent-shell-window--session-configuration session) nil))
        (unless (frame-live-p (agent-shell-window--session-frame session))
          (setf (agent-shell-window--session-frame session)
                (or (when-let ((window (get-buffer-window (current-buffer) 'visible)))
                      (window-frame window))
                    (selected-frame))))
        (setf (agent-shell-window--session-active session) t)
        (if (and (not initial) (agent-shell-window--shell-window session))
            (agent-shell-window--layout session nil)
          (agent-shell-window--enter session before outgoing))
        session))))

;;;###autoload
(defun agent-shell-window-stop (&optional shell)
  "Stop file viewing for SHELL, leaving its current layout in place."
  (interactive (list (agent-shell-window--read-shell)))
  (with-current-buffer (or shell (current-buffer))
    (when agent-shell-window--session
      (setf (agent-shell-window--session-active agent-shell-window--session) nil))))

(defun agent-shell-window--required (key object)
  "Return KEY in OBJECT, signaling an error when it is absent."
  (if-let ((entry (assq key object)))
      (cdr entry)
    (error "Missing required value: %s" key)))

(defun agent-shell-window--check-file (session file)
  "Resolve FILE and enforce SESSION's directory boundary."
  (let ((real (file-truename file)))
    (unless (file-in-directory-p real (agent-shell-window--session-root session))
      (user-error "The file must be inside this session's working directory"))
    real))

(defun agent-shell-window--resolve-file (session file)
  "Resolve a relative FILE within SESSION's directory."
  (unless (and (stringp file) (not (string-empty-p file))
               (not (file-name-absolute-p file)) (not (file-remote-p file)))
    (user-error "Supply a path relative to this session's working directory"))
  (let ((real (agent-shell-window--check-file
               session (expand-file-name file (agent-shell-window--session-root session)))))
    (unless (file-regular-p real) (user-error "Choose an existing regular file"))
    real))

(defun agent-shell-window--file-buffer (session file)
  "Return SESSION's own view of FILE's live text, refreshing clean text."
  (let* ((base (or (find-buffer-visiting file) (find-file-noselect file)))
         (view (agent-shell-window--session-buffer session)))
    (with-current-buffer base
      (when (and (not (buffer-modified-p)) (not (verify-visited-file-modtime base)))
        (revert-buffer t t))
      (unless (and (buffer-live-p view) (eq (buffer-base-buffer view) base))
        (when (buffer-live-p view) (kill-buffer view))
        (setq view (clone-indirect-buffer (agent-shell-window--buffer-name session) nil))
        (setf (agent-shell-window--session-buffer session) view)))
    view))

(defun agent-shell-window--position (coordinates)
  "Resolve [line, character] COORDINATES in the current buffer.
Coordinates past the end of the line or buffer clamp to the line."
  (goto-char (point-min))
  (forward-line (1- (aref coordinates 0)))
  (goto-char (min (+ (point) (aref coordinates 1)) (line-end-position)))
  (point))

(defun agent-shell-window--coordinates (position)
  "Return [line, character] coordinates for POSITION in the current buffer."
  (save-excursion
    (goto-char position)
    (vector (line-number-at-pos position t) (- position (line-beginning-position)))))

(defun agent-shell-window--show-file (session arguments)
  "Display ARGUMENTS in SESSION, or retain them while it is hidden."
  (unless (agent-shell-window--session-active session)
    (user-error "This window session is stopped; start it through Emacs"))
  (let ((file (agent-shell-window--resolve-file
               session (agent-shell-window--required 'file arguments)))
        (highlights (agent-shell-window--required 'highlights arguments))
        (top-line (agent-shell-window--required
                   'top_line (agent-shell-window--required 'viewport arguments))))
    (setf (agent-shell-window--session-request session) arguments)
    (when (agent-shell-window--shell-window session)
      (save-selected-window
        (let* ((view (agent-shell-window--file-buffer session file))
               (window (agent-shell-window--layout session nil)))
          (mapc #'delete-overlay (agent-shell-window--session-overlays session))
          (setf (agent-shell-window--session-overlays session) nil)
          (with-current-buffer view
            (widen)
            (mapc
             (lambda (range)
               (let ((overlay
                      (make-overlay
                       (agent-shell-window--position
                        (agent-shell-window--required 'start range))
                       (agent-shell-window--position
                        (agent-shell-window--required 'end range)) view)))
                 (overlay-put overlay 'face 'highlight)
                 (overlay-put overlay 'window window)
                 (push overlay (agent-shell-window--session-overlays session))))
             highlights)
            (goto-char (point-min))
            (forward-line (1- top-line))
            (set-window-point window (point))
            (set-window-start window (point))))
        (setf (agent-shell-window--session-request session) nil)))
    (agent-shell-window--get-view session)))

(defun agent-shell-window--visible-text (window start end)
  "Return WINDOW's text from START to END, replacing folded spans."
  (with-selected-window window
    (let ((position start) pieces hidden)
      (while (< position end)
        (let* ((next (next-char-property-change position end))
               (invisible (invisible-p position)))
          (push (cond ((and invisible (not hidden)) "…")
                      (invisible "")
                      (t (buffer-substring-no-properties position next)))
                pieces)
          (setq position next hidden invisible)))
      (apply #'concat (nreverse pieces)))))

(defun agent-shell-window--get-view (session)
  "Read SESSION's actual visible live text, or report its state."
  (let* ((window (agent-shell-window--display-window session))
         (status (cond ((not (agent-shell-window--session-active session)) "stopped")
                       ((not (agent-shell-window--shell-window session)) "hidden")
                       ((not (and window
                                  (buffer-live-p (agent-shell-window--session-buffer session))))
                        "closed")
                       (t "visible"))))
    (if (not (equal status "visible"))
        (list (cons 'status status))
      (with-current-buffer (window-buffer window)
        (let* ((base (or (buffer-base-buffer) (current-buffer)))
               (file (buffer-file-name base)))
          (if (not file)
              (list (cons 'status "empty"))
          (setq file (agent-shell-window--check-file session file))
          (redisplay t)
          (save-restriction
            (widen)
            (let ((start (window-start window))
                  (end (window-end window t)))
              `((status . "visible")
                (file . ,(file-relative-name file (agent-shell-window--session-root session)))
                (buffer . ,(buffer-name))
                (mode . ,(symbol-name major-mode))
                (modified . ,(if (buffer-modified-p) t :json-false))
                (cursor . ,(agent-shell-window--coordinates (window-point window)))
                (visible . ((start . ,(agent-shell-window--coordinates start))
                            (end . ,(agent-shell-window--coordinates end))
                            (text . ,(agent-shell-window--visible-text window start end))))
                (highlights .
                            ,(vconcat
                              (mapcar
                               (lambda (overlay)
                                 `((start . ,(agent-shell-window--coordinates (overlay-start overlay)))
                                   (end . ,(agent-shell-window--coordinates (overlay-end overlay)))))
                               (cl-remove-if-not
                                (lambda (overlay) (eq (overlay-buffer overlay) (current-buffer)))
                                (reverse (agent-shell-window--session-overlays session)))))))))))))))

(provide 'agent-shell-window)
;;; agent-shell-window.el ends here
