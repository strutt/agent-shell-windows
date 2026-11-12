;;; agent-shell-windows.el --- Show files beside agent-shell -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.95.1") (web-server "0.1.2"))

;;; Commentary:

;; Add this directory to `load-path' and require agent-shell-windows before
;; starting an agent connection.  MCP registration is automatic.  Use
;; `agent-shell-windows-start' and `agent-shell-windows-stop' in the shell
;; buffer to control whether its agent may display files.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'autorevert)
(require 'agent-shell)

(defgroup agent-shell-windows nil
  "View files beside an agent-shell conversation."
  :group 'tools)

(defcustom agent-shell-windows-mcp-url "http://localhost:8765/mcp"
  "MCP URL advertised to the agent.
Set this through directory-local variables when the agent needs a
different address, such as http://host.docker.internal:8765/mcp."
  :type 'string
  :group 'agent-shell-windows)
(make-variable-buffer-local 'agent-shell-windows-mcp-url)

(cl-defstruct (agent-shell-windows--session
               (:constructor agent-shell-windows--make-session))
  id shell root active frame panes (count 1) configuration previous)

(cl-defstruct (agent-shell-windows--pane
               (:constructor agent-shell-windows--make-pane))
  id buffer request overlays start point)

(defvar agent-shell-windows--sessions (make-hash-table :test #'equal))
(defvar-local agent-shell-windows--session nil)
(defvar agent-shell-prefer-viewport-interaction)

(add-to-list 'window-persistent-parameters '(agent-shell-windows-session . t))
(add-to-list 'window-persistent-parameters '(agent-shell-windows-pane . t))

(declare-function agent-shell-windows-http--ensure "agent-shell-windows-http" ())
(declare-function agent-shell--current-shell "agent-shell" ())
(declare-function agent-shell-project-buffers "agent-shell" ())
(declare-function agent-shell-buffers "agent-shell" ())
(declare-function agent-shell-viewport--buffer "agent-shell-viewport" (&rest arguments))
(declare-function agent-shell--state "agent-shell" ())
(declare-function agent-shell--make-header-model "agent-shell" (&rest arguments))
(declare-function agent-shell--svg-header-geometry "agent-shell" (model))
(declare-function agent-shell--fetch-agent-icon "agent-shell" (name))
(declare-function agent-shell--make-agent-fallback-icon "agent-shell" (name width))
(declare-function agent-shell--image-type-to-mime "agent-shell" (filename))

(defun agent-shell-windows--register ()
  "Return the current shell's routing association, creating it if needed."
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Choose an agent-shell buffer"))
  (unless agent-shell-windows--session
    (let ((id (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert-file-contents-literally "/dev/urandom" nil nil 32)
                (secure-hash 'sha256 (current-buffer)))))
      (setq agent-shell-windows--session
            (agent-shell-windows--make-session :id id :shell (current-buffer)))
      (puthash id agent-shell-windows--session agent-shell-windows--sessions)
      (add-hook 'kill-buffer-hook #'agent-shell-windows--unregister nil t)))
  agent-shell-windows--session)

(defun agent-shell-windows--pane (session &optional id)
  "Return SESSION's pane ID, defaulting to 1, validating its configured range."
  (setq id (or id 1))
  (unless (and (integerp id) (<= 1 id (agent-shell-windows--session-count session)))
    (user-error "Choose a configured pane from 1 to %s"
                (agent-shell-windows--session-count session)))
  (unless (agent-shell-windows--session-panes session)
    (setf (agent-shell-windows--session-panes session)
          (vconcat (mapcar (lambda (n) (agent-shell-windows--make-pane :id n)) '(1 2 3)))))
  (aref (agent-shell-windows--session-panes session) (1- id)))

(defun agent-shell-windows--unregister ()
  "Remove the current shell's routing association and all pane highlights."
  (when agent-shell-windows--session
    (mapc (lambda (pane) (mapc #'delete-overlay (agent-shell-windows--pane-overlays pane)))
          (agent-shell-windows--session-panes agent-shell-windows--session))
    (remhash (agent-shell-windows--session-id agent-shell-windows--session)
             agent-shell-windows--sessions)))

(defun agent-shell-windows--ensure-server ()
  "Ensure the shared HTTP server is running."
  (require 'agent-shell-windows-http)
  (agent-shell-windows-http--ensure))

(defun agent-shell-windows--before-agent-start (&rest _arguments)
  "Ensure the shared listener exists before agent-shell starts a shell.
Keep agent startup available if the listener cannot be started."
  (condition-case err
      (agent-shell-windows--ensure-server)
    ((error quit)
     (display-warning
      'agent-shell-windows
      (format "Could not start the file-viewing server: %s"
              (error-message-string err))))))

(defun agent-shell-windows--mcp-servers (servers)
  "Append this shell's MCP connection to normalized SERVERS.
A failure here must not prevent the session from starting, so on
error the shell proceeds without file viewing."
  (condition-case err
      (progn
        (agent-shell-windows--ensure-server)
        (let ((session (agent-shell-windows--register)))
          ;; First activation assigns the root.  Preserve an explicit stop
          ;; when the same conversation reconnects.
          (unless (agent-shell-windows--session-root session)
            (agent-shell-windows-start))
          (vconcat
           (cl-remove-if
            (lambda (server) (equal (alist-get 'name server) "agent-shell-windows"))
            (append servers nil))
           (vector
            `((name . "agent-shell-windows")
              (type . "http")
              (url . ,agent-shell-windows-mcp-url)
              (headers . [((name . "X-Agent-Shell-Windows-Session")
                           (value . ,(agent-shell-windows--session-id session)))]))))))
    ((error quit)
     (display-warning
      'agent-shell-windows
      (format "File viewing is unavailable for this session: %s"
              (error-message-string err)))
     servers)))

(with-eval-after-load 'agent-shell
  ;; The mode hook runs after ACP startup, too late to prepare the listener.
  (advice-add 'agent-shell--start :before #'agent-shell-windows--before-agent-start)
  (advice-add 'agent-shell--mcp-servers :filter-return
              #'agent-shell-windows--mcp-servers)
  (advice-add 'agent-shell-switch-buffer :around #'agent-shell-windows--switch-buffer)
  (advice-add 'agent-shell--display-buffer :around #'agent-shell-windows--display-buffer)
  (advice-add 'agent-shell-toggle :around #'agent-shell-windows--toggle))

(defun agent-shell-windows--read-shell ()
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

(defun agent-shell-windows--shell-window (session)
  "Return SESSION's visible shell window in its owning frame."
  (let ((frame (agent-shell-windows--session-frame session)))
    (when (and (frame-live-p frame) (frame-visible-p frame))
      (get-buffer-window (agent-shell-windows--session-shell session) frame))))

(defun agent-shell-windows--windows (session)
  "Return all windows owned by SESSION in its frame."
  (when (and session (frame-live-p (agent-shell-windows--session-frame session)))
    (cl-remove-if-not
     (lambda (window)
       (eq (window-parameter window 'agent-shell-windows-session) session))
     (window-list (agent-shell-windows--session-frame session) 'nomini))))

(defun agent-shell-windows--display-window (session &optional id)
  "Find SESSION's pane ID, including after restoring a configuration."
  (let* ((pane (agent-shell-windows--pane session id))
         (window (cl-find-if
                  (lambda (window)
                    (eql (window-parameter window 'agent-shell-windows-pane)
                         (agent-shell-windows--pane-id pane)))
                  (agent-shell-windows--windows session))))
    (dolist (overlay (agent-shell-windows--pane-overlays pane))
      ;; An absent pane must not make its overlays visible in other windows.
      (overlay-put overlay 'window (or window 'agent-shell-windows-hidden)))
    window))

(defun agent-shell-windows--complete-p (session)
  "Return non-nil when all configured panes in SESSION are visible."
  (cl-loop for id from 1 to (agent-shell-windows--session-count session)
           always (agent-shell-windows--display-window session id)))

(defun agent-shell-windows--has-display-p (session)
  "Return non-nil when SESSION has a saved or requested display."
  (or (agent-shell-windows--session-configuration session)
      (cl-some (lambda (pane)
                 (or (agent-shell-windows--pane-buffer pane)
                     (agent-shell-windows--pane-request pane)))
               (append (agent-shell-windows--session-panes session) nil))))

(defun agent-shell-windows--buffer-session (buffer)
  "Return BUFFER's association, resolving an agent-shell viewport if needed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (or agent-shell-windows--session
          (when-let* ((shell (agent-shell--current-shell)))
            (buffer-local-value 'agent-shell-windows--session shell))))))

(defun agent-shell-windows--visible-session ()
  "Return the associated shell visible in the selected frame."
  (cl-find-if
   (lambda (session)
     (and (eq (agent-shell-windows--session-frame session) (selected-frame))
          (agent-shell-windows--shell-window session)))
   (hash-table-values agent-shell-windows--sessions)))

(defun agent-shell-windows--save (session)
  "Save an active SESSION's complete chat and display configuration."
  (when (and session (agent-shell-windows--session-active session)
             (agent-shell-windows--shell-window session)
             (agent-shell-windows--complete-p session))
    (setf (agent-shell-windows--session-configuration session)
          (current-window-configuration (agent-shell-windows--session-frame session)))))

(defun agent-shell-windows--refresh-view (session)
  "Reattach SESSION's highlights and apply pending requests for each pane."
  (dotimes (index (agent-shell-windows--session-count session))
    (let* ((id (1+ index))
           (pane (agent-shell-windows--pane session id))
           (window (agent-shell-windows--display-window session id)))
      (when window (agent-shell-windows--set-header session window))
      (when (and (agent-shell-windows--session-active session)
                 (agent-shell-windows--pane-request pane))
        (condition-case err
            (agent-shell-windows--show-file session (agent-shell-windows--pane-request pane))
          ((error quit)
           (setf (agent-shell-windows--pane-request pane) nil)
           (message "agent-shell-windows: dropped pane %s request (%s)"
                    id (error-message-string err))))))))

(defun agent-shell-windows--enter (session before outgoing)
  "Restore SESSION when leaving OUTGOING, with BEFORE as the prior layout."
  (unless (frame-live-p (agent-shell-windows--session-frame session))
    (setf (agent-shell-windows--session-frame session) (selected-frame)
          (agent-shell-windows--session-configuration session) nil
          (agent-shell-windows--session-previous session) nil))
  (let ((frame (agent-shell-windows--session-frame session)))
    (when (and (not (eq session outgoing))
               (eq frame (window-configuration-frame before)))
      (setf (agent-shell-windows--session-previous session) before))
    (unless (agent-shell-windows--session-previous session)
      (setf (agent-shell-windows--session-previous session)
            (current-window-configuration frame)))
    ;; A native switch may already have changed the caller's other frame.
    (unless (eq frame (window-configuration-frame before))
      (set-window-configuration before))
    (select-frame-set-input-focus frame)
    (if-let* ((configuration (agent-shell-windows--session-configuration session)))
        (set-window-configuration configuration)
      (agent-shell-windows--layout session t))
    ;; Older snapshots, or snapshots whose view buffer was killed, may
    ;; restore without the display pane.  Reuse the live view and its point.
    (agent-shell-windows--layout session nil)
    (agent-shell-windows--refresh-view session)
    (agent-shell-windows--shell-window session)))

(defun agent-shell-windows--remove-display (session)
  "Remove all of SESSION's file panes from the current layout."
  (dolist (window (agent-shell-windows--windows session))
    (delete-window window))
  (when session
    (dotimes (index (agent-shell-windows--session-count session))
      (agent-shell-windows--display-window session (1+ index)))))

(defun agent-shell-windows--switch-buffer (original &rest arguments)
  "Preserve session layouts around the native switch command ORIGINAL."
  (let ((before (current-window-configuration))
        (outgoing (agent-shell-windows--visible-session)))
    (agent-shell-windows--save outgoing)
    (let* ((buffer (apply original arguments))
           (incoming (agent-shell-windows--buffer-session buffer)))
      (if (and incoming (agent-shell-windows--session-active incoming)
             (agent-shell-windows--has-display-p incoming))
          (agent-shell-windows--enter incoming before outgoing)
        (when incoming
          (setf (agent-shell-windows--session-previous incoming) before))
        (when outgoing
          (set-window-configuration before)
          (agent-shell-windows--remove-display outgoing)
          (switch-to-buffer buffer)))
      buffer)))

(defun agent-shell-windows--display-buffer (original buffer)
  "Display BUFFER through ORIGINAL or its saved window session."
  (let ((incoming (agent-shell-windows--buffer-session buffer))
        (outgoing (agent-shell-windows--visible-session))
        (before (current-window-configuration)))
    (agent-shell-windows--save outgoing)
    (if (and incoming (agent-shell-windows--session-active incoming)
             (agent-shell-windows--has-display-p incoming))
        (agent-shell-windows--enter incoming before outgoing)
      (when incoming
        (setf (agent-shell-windows--session-previous incoming) before))
      (agent-shell-windows--remove-display outgoing)
      (funcall original buffer))))

(defun agent-shell-windows--hide (session)
  "Hide SESSION's pair and return to its previous layout."
  (agent-shell-windows--save session)
  (let ((chat (agent-shell-windows--shell-window session))
        (previous (agent-shell-windows--session-previous session)))
    (agent-shell-windows--remove-display session)
    (when (window-live-p chat) (quit-restore-window chat 'bury))
    (when (and previous (frame-live-p (window-configuration-frame previous)))
      (set-window-configuration previous)
      ;; Activation may have happened after the chat was already displayed.
      (when-let* ((window (get-buffer-window (agent-shell-windows--session-shell session))))
        (quit-restore-window window 'bury))
      (when-let* ((restored (agent-shell-windows--visible-session)))
        (agent-shell-windows--refresh-view restored)))))

(defun agent-shell-windows--toggle (original &rest arguments)
  "Toggle saved layouts while preserving ORIGINAL's shell selection rules."
  (let* ((buffer (if agent-shell-prefer-viewport-interaction
                     (agent-shell-viewport--buffer)
                   (or (agent-shell--current-shell)
                       (car (agent-shell-project-buffers))
                       (car (agent-shell-buffers)))))
         (session (agent-shell-windows--buffer-session buffer)))
    (if (and session (agent-shell-windows--session-active session)
             (agent-shell-windows--has-display-p session))
        (if (agent-shell-windows--shell-window session)
            (agent-shell-windows--hide session)
          (let ((before (current-window-configuration))
                (outgoing (agent-shell-windows--visible-session)))
            (agent-shell-windows--save outgoing)
            (agent-shell-windows--enter session before outgoing)))
      (apply original arguments))))

(defun agent-shell-windows--buffer-name (session &optional id)
  "Return the empty display buffer name for SESSION."
  (format "*agent-shell-windows: %s / %s*"
          (buffer-name (agent-shell-windows--session-shell session)) (or id 1)))

(defun agent-shell-windows--set-header (session window)
  "Label WINDOW with SESSION's icon and a short title."
  (when (and (fboundp 'agent-shell--make-header-model)
             (fboundp 'agent-shell--svg-header-geometry))
    (with-current-buffer (agent-shell-windows--session-shell session)
      (when (derived-mode-p 'agent-shell-mode)
        (set-window-parameter
         window 'header-line-format
         (list
          (if (and (display-graphic-p) (image-type-available-p 'svg))
              (let* ((model (agent-shell--make-header-model (agent-shell--state)))
                     (geometry (agent-shell--svg-header-geometry model))
                     (icon (if (map-elt model :icon-name)
                               (agent-shell--fetch-agent-icon (map-elt model :icon-name))
                             (agent-shell--make-agent-fallback-icon
                              (map-elt model :buffer-name) 100)))
                     (height (map-elt geometry :total-height))
                     (svg (progn (require 'svg)
                                 (svg-create (window-pixel-width window) height))))
                (when icon
                  (svg-embed svg icon (agent-shell--image-type-to-mime icon) nil
                             :x (map-elt geometry :icon-x)
                             :y (map-elt geometry :icon-y)
                             :width (map-elt geometry :image-width)
                             :height (map-elt geometry :image-height)))
                (svg-text svg (format "agent-shell-windows · %s"
                                      (window-parameter window 'agent-shell-windows-pane))
                          :x (map-elt geometry :icon-text-x)
                          :y (+ (/ height 2) (/ (map-elt model :font-size) 3))
                          :font-family (map-elt model :font-family)
                          :font-size (map-elt model :font-size)
                          :fill (face-foreground 'default nil t))
                (propertize " " 'display (svg-image svg :scale 1)))
            (format " agent-shell-windows · %s"
                    (window-parameter window 'agent-shell-windows-pane)))))))))

(defun agent-shell-windows--remember-positions (session)
  "Remember each visible pane's position before changing SESSION's layout."
  (dotimes (index (agent-shell-windows--session-count session))
    (let* ((pane (agent-shell-windows--pane session (1+ index)))
           (window (agent-shell-windows--display-window session (1+ index))))
      (when (and window (eq (window-buffer window) (agent-shell-windows--pane-buffer pane)))
        (setf (agent-shell-windows--pane-start pane) (window-start window)
              (agent-shell-windows--pane-point pane) (window-point window))))))

(defun agent-shell-windows--split (window)
  "Split WINDOW using Emacs's heuristic, with a minimum-size fallback."
  (let ((dedicated (window-dedicated-p window)))
    (unwind-protect
        (progn
          (set-window-dedicated-p window nil)
          (or (split-window-sensibly window)
              ;; Thresholds are preferences; if neither is met, try a
              ;; half split that still respects Emacs's minimum sizes.
              (ignore-errors (split-window window nil 'below))
              (split-window window nil 'right)))
      (set-window-dedicated-p window dedicated))))

(defun agent-shell-windows--attach-pane (session id window)
  "Attach SESSION's pane ID to WINDOW without disturbing an existing view."
  (let* ((pane (agent-shell-windows--pane session id))
         (view (agent-shell-windows--pane-buffer pane)))
    (unless (buffer-live-p view)
      (setq view (generate-new-buffer (agent-shell-windows--buffer-name session id)))
      (with-current-buffer view
        (setq default-directory (agent-shell-windows--session-root session)))
      (setf (agent-shell-windows--pane-buffer pane) view
            (agent-shell-windows--pane-start pane) nil
            (agent-shell-windows--pane-point pane) nil))
    (set-window-parameter window 'agent-shell-windows-session session)
    (set-window-parameter window 'agent-shell-windows-pane id)
    (set-window-dedicated-p window nil)
    (unwind-protect
        (unless (eq (window-buffer window) view)
          (set-window-buffer window view)
          (when (agent-shell-windows--pane-point pane)
            (set-window-point window (agent-shell-windows--pane-point pane)))
          (when (agent-shell-windows--pane-start pane)
            (set-window-start window (agent-shell-windows--pane-start pane))))
      (set-window-dedicated-p window t))
    (agent-shell-windows--set-header session window)
    (agent-shell-windows--display-window session id)
    window))

(defun agent-shell-windows--layout (session initial)
  "Show SESSION's automatic layout, resetting it when INITIAL is non-nil."
  (with-selected-frame (agent-shell-windows--session-frame session)
    (let ((chat (or (agent-shell-windows--shell-window session) (selected-window)))
          (count (agent-shell-windows--session-count session)))
      (agent-shell-windows--remember-positions session)
      (when initial
        (set-window-parameter chat 'agent-shell-windows-session nil)
        (set-window-parameter chat 'agent-shell-windows-pane nil)
        (set-window-parameter chat 'header-line-format nil)
        (set-window-dedicated-p chat nil)
        (set-window-buffer chat (agent-shell-windows--session-shell session))
        (delete-other-windows chat))
      ;; Remove panes above the new count, without killing any file buffers.
      (dolist (window (agent-shell-windows--windows session))
        (when (> (window-parameter window 'agent-shell-windows-pane) count)
          (delete-window window)))
      ;; Shrinking a grid to two panes must subdivide only the file area.
      (when (= count 2)
        (let ((first (agent-shell-windows--display-window session 1))
              (second (agent-shell-windows--display-window session 2)))
          (when (and first second
                     (not (eq (window-parent first) (window-parent second))))
            (delete-window second))))
      (unless (agent-shell-windows--complete-p session)
        (if (= count 3)
            ;; Four equal quadrants: chat, pane 1, pane 2, pane 3.
            (progn
              (delete-other-windows chat)
              (let* ((right (split-window chat nil 'right))
                     (bottom-left (split-window chat nil 'below))
                     (bottom-right (split-window right nil 'below)))
                (agent-shell-windows--attach-pane session 1 right)
                (agent-shell-windows--attach-pane session 2 bottom-left)
                (agent-shell-windows--attach-pane session 3 bottom-right)))
          (let ((first (or (agent-shell-windows--display-window session 1)
                           (agent-shell-windows--attach-pane
                            session 1 (agent-shell-windows--split chat)))))
            (when (and (= count 2) (not (agent-shell-windows--display-window session 2)))
              (let ((second (agent-shell-windows--split first)))
                ;; Splitting can copy the original pane's parameters.
                (set-window-parameter second 'agent-shell-windows-session nil)
                (agent-shell-windows--attach-pane session 2 second))))))
      (dotimes (index count)
        (let ((window (agent-shell-windows--display-window session (1+ index))))
          (agent-shell-windows--attach-pane session (1+ index) window)))
      (agent-shell-windows--save session)
      (agent-shell-windows--display-window session 1))))

(defun agent-shell-windows--set-panes (session count)
  "Configure SESSION for COUNT file panes, from 1 to 3."
  (unless (agent-shell-windows--session-active session)
    (user-error "This window session is stopped; start it through Emacs"))
  (unless (and (integerp count) (<= 1 count 3))
    (user-error "Pane count must be 1, 2, or 3"))
  (let ((old-count (agent-shell-windows--session-count session))
        (before (current-window-configuration
                 (if (frame-live-p (agent-shell-windows--session-frame session))
                     (agent-shell-windows--session-frame session)
                   (selected-frame))))
        (saved (agent-shell-windows--session-configuration session)))
    (agent-shell-windows--remember-positions session)
    (setf (agent-shell-windows--session-count session) count)
    (condition-case err
        (when (agent-shell-windows--shell-window session)
          (save-selected-window
            (agent-shell-windows--layout session nil)))
      ((error quit)
       (setf (agent-shell-windows--session-count session) old-count
             (agent-shell-windows--session-configuration session) saved)
       (set-window-configuration before)
       (agent-shell-windows--refresh-view session)
       (signal (car err) (cdr err))))
    ;; Removed panes must never leave highlights on ordinary file windows.
    (cl-loop for id from (1+ count) to 3
             for pane = (aref (agent-shell-windows--session-panes session) (1- id))
             do (mapc #'delete-overlay (agent-shell-windows--pane-overlays pane))
             do (setf (agent-shell-windows--pane-overlays pane) nil
                      (agent-shell-windows--pane-request pane) nil))
    `((status . ,(if (agent-shell-windows--shell-window session) "visible" "hidden"))
      (count . ,count)
      (panes . ,(vconcat (number-sequence 1 count))))))

;;;###autoload
(defun agent-shell-windows-start (&optional shell)
  "Activate file viewing for SHELL, or the current agent-shell buffer.
Leave the frame unchanged until the session requests a display."
  (interactive (list (agent-shell-windows--read-shell)))
  (let ((before (current-window-configuration))
        (outgoing (agent-shell-windows--visible-session)))
    (agent-shell-windows--save outgoing)
    (with-current-buffer (or shell (current-buffer))
      (let* ((session (agent-shell-windows--register))
             (initial (not (agent-shell-windows--session-active session))))
        (agent-shell-windows--ensure-server)
        (when initial
          (setf (agent-shell-windows--session-root session)
                (file-name-as-directory (file-truename default-directory))
                (agent-shell-windows--session-configuration session) nil)
          (mapc (lambda (pane) (setf (agent-shell-windows--pane-request pane) nil))
                (agent-shell-windows--session-panes session)))
        (unless (frame-live-p (agent-shell-windows--session-frame session))
          (setf (agent-shell-windows--session-frame session)
                (or (when-let* ((window (get-buffer-window (current-buffer) 'visible)))
                      (window-frame window))
                    (selected-frame))))
        (setf (agent-shell-windows--session-active session) t)
        (when (agent-shell-windows--has-display-p session)
          (if (and (not initial) (agent-shell-windows--shell-window session))
              (agent-shell-windows--layout session nil)
            (agent-shell-windows--enter session before outgoing)))
        session))))

;;;###autoload
(defun agent-shell-windows-stop (&optional shell)
  "Stop file viewing for SHELL, leaving its current layout in place."
  (interactive (list (agent-shell-windows--read-shell)))
  (with-current-buffer (or shell (current-buffer))
    (when agent-shell-windows--session
      (setf (agent-shell-windows--session-active agent-shell-windows--session) nil))))

(defun agent-shell-windows--required (key object)
  "Return KEY in OBJECT, signaling an error when it is absent."
  (if-let* ((entry (assq key object)))
      (cdr entry)
    (error "Missing required value: %s" key)))

(defun agent-shell-windows--check-file (session file)
  "Resolve FILE and enforce SESSION's directory boundary."
  (let ((real (file-truename file)))
    (unless (file-in-directory-p real (agent-shell-windows--session-root session))
      (user-error "The file must be inside this session's working directory"))
    real))

(defun agent-shell-windows--resolve-file (session file)
  "Resolve a relative FILE within SESSION's directory."
  (unless (and (stringp file) (not (string-empty-p file))
               (not (file-name-absolute-p file)) (not (file-remote-p file)))
    (user-error "Supply a path relative to this session's working directory"))
  (let ((real (agent-shell-windows--check-file
               session (expand-file-name file (agent-shell-windows--session-root session)))))
    (unless (file-regular-p real) (user-error "Choose an existing regular file"))
    real))

(defun agent-shell-windows--file-buffer (session file &optional id)
  "Return FILE's normal buffer for SESSION with automatic disk refresh."
  (let ((base (or (find-buffer-visiting file) (find-file-noselect file))))
    (with-current-buffer base
      (auto-revert-mode 1)
      (when (and (not (buffer-modified-p)) (not (verify-visited-file-modtime base)))
        (revert-buffer t t)))
    (let ((pane (agent-shell-windows--pane session id)))
      (unless (eq base (agent-shell-windows--pane-buffer pane))
        (setf (agent-shell-windows--pane-start pane) nil
              (agent-shell-windows--pane-point pane) nil))
      (setf (agent-shell-windows--pane-buffer pane) base))
    base))

(defun agent-shell-windows--position (coordinates)
  "Resolve [line, character] COORDINATES in the current buffer.
Coordinates past the end of the line or buffer clamp to the line."
  (goto-char (point-min))
  (forward-line (1- (aref coordinates 0)))
  (goto-char (min (+ (point) (aref coordinates 1)) (line-end-position)))
  (point))

(defun agent-shell-windows--show-file (session arguments)
  "Display ARGUMENTS in SESSION, or retain them while it is hidden."
  (unless (agent-shell-windows--session-active session)
    (user-error "This window session is stopped; start it through Emacs"))
  (let* ((pane (agent-shell-windows--pane session (alist-get 'pane arguments)))
         (id (agent-shell-windows--pane-id pane))
         (file (agent-shell-windows--resolve-file
		session (agent-shell-windows--required 'file arguments)))
         (highlights (agent-shell-windows--required 'highlights arguments))
         (top-line (agent-shell-windows--required
                    'top_line (agent-shell-windows--required 'viewport arguments))))
    (setf (agent-shell-windows--pane-request pane) arguments)
    (when (agent-shell-windows--shell-window session)
      (save-selected-window
        (let* ((view (agent-shell-windows--file-buffer session file id))
               (window (progn (agent-shell-windows--layout session nil)
                              (agent-shell-windows--display-window session id))))
          (mapc #'delete-overlay (agent-shell-windows--pane-overlays pane))
          (setf (agent-shell-windows--pane-overlays pane) nil)
          (with-current-buffer view
            (save-excursion
              (save-restriction
		(widen)
		(mapc
		 (lambda (range)
		   (let ((overlay
			  (make-overlay
			   (agent-shell-windows--position
                            (agent-shell-windows--required 'start range))
			   (agent-shell-windows--position
                            (agent-shell-windows--required 'end range)) view)))
                     (overlay-put overlay 'face 'highlight)
                     (overlay-put overlay 'window window)
                     (push overlay (agent-shell-windows--pane-overlays pane))))
		 highlights)
		(goto-char (point-min))
		(forward-line (1- top-line))
		(set-window-point window (point))
		(set-window-start window (point))))))
        (setf (agent-shell-windows--pane-request pane) nil)))
    (agent-shell-windows--save session)
    `((status . ,(if (agent-shell-windows--shell-window session) "visible" "hidden")))))

(defun agent-shell-windows--validate-request (session request id)
  "Validate one complete pane REQUEST for SESSION at position ID."
  (unless (and (listp request) (cl-every #'consp request)
               (eql id (agent-shell-windows--required 'pane request)))
    (user-error "List panes in order, numbered 1, 2, 3"))
  (agent-shell-windows--resolve-file session (agent-shell-windows--required 'file request))
  (let ((highlights (agent-shell-windows--required 'highlights request))
        (top (agent-shell-windows--required
              'top_line (agent-shell-windows--required 'viewport request))))
    (unless (and (integerp top) (>= top 1))
      (user-error "viewport.top_line must be a positive integer"))
    (unless (vectorp highlights) (user-error "highlights must be an array"))
    (mapc
     (lambda (range)
       (dolist (key '(start end))
         (let ((position (agent-shell-windows--required key range)))
           (unless (and (vectorp position) (= 2 (length position))
                        (integerp (aref position 0)) (>= (aref position 0) 1)
                        (integerp (aref position 1)) (>= (aref position 1) 0))
             (user-error "Highlight endpoints must be [line >= 1, column >= 0]")))))
     highlights)))

(defun agent-shell-windows--show-files (session arguments)
  "Replace SESSION's complete display with ARGUMENTS' ordered panes array."
  (unless (agent-shell-windows--session-active session)
    (user-error "This window session is stopped; start it through Emacs"))
  (let ((requests (agent-shell-windows--required 'panes arguments)))
    (unless (and (vectorp requests) (<= 1 (length requests) 3))
      (user-error "Supply an array of 1 to 3 complete panes"))
    ;; Validate the whole display before changing any windows or requests.
    (cl-loop for request across requests for id from 1
             do (agent-shell-windows--validate-request session request id))
    (save-selected-window
      (agent-shell-windows--set-panes session (length requests))
      (mapc (lambda (request) (agent-shell-windows--show-file session request)) requests))
    `((status . ,(if (agent-shell-windows--shell-window session) "visible" "hidden"))
      (count . ,(length requests)))))

(provide 'agent-shell-windows)
;;; agent-shell-windows.el ends here
