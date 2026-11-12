;;; agent-shell-window-test.el --- Layout regression tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'agent-shell-window)
(ert-deftest agent-shell-window-restores-collapsed-pair ()
  (save-window-excursion
    (let* ((shell (generate-new-buffer " *asw-test-shell*"))
           (session (agent-shell-window--make-session
                     :shell shell :active t :frame (selected-frame)
                     :root default-directory))
           (before (current-window-configuration))
           (agent-shell-window--sessions (make-hash-table :test #'equal)))
      (puthash "test" session agent-shell-window--sessions)
      (with-current-buffer shell (setq-local agent-shell-window--session session))
      (unwind-protect
          (progn
            (agent-shell-window--layout session t)
            (let ((view (agent-shell-window--display-window session)))
              (window-resize view -7 t)
              (agent-shell-window--save session)
              (let ((width (window-total-width view)))
                (delete-window view)
                (agent-shell-window--switch-buffer (lambda () (switch-to-buffer shell)))
                (should (agent-shell-window--display-window session))
                (should (= width (window-total-width (agent-shell-window--display-window session)))))))
        (set-window-configuration before)
        (when (buffer-live-p (agent-shell-window--session-buffer session))
          (kill-buffer (agent-shell-window--session-buffer session)))
        (kill-buffer shell)))))

(ert-deftest agent-shell-window-uses-normal-file-buffer ()
  (let* ((file (make-temp-file "agent-shell-window-test-" nil ".el" ";;; Example\n"))
         (session (agent-shell-window--make-session))
         (base (find-file-noselect file)))
    (unwind-protect
        (progn
          (should (eq base (agent-shell-window--file-buffer session file)))
          (should-not (buffer-base-buffer (agent-shell-window--session-buffer session)))
          (with-current-buffer base
            (goto-char (point-max))
            (insert ";; Unsaved edit\n"))
          (should (eq base (agent-shell-window--file-buffer session file)))
          (should (buffer-modified-p base)))
      (with-current-buffer base (set-buffer-modified-p nil))
      (kill-buffer base)
      (delete-file file))))

(ert-deftest agent-shell-window-dedicates-file-pane ()
  (save-window-excursion
    (let* ((shell (generate-new-buffer " *asw-dedication-shell*"))
           (other (generate-new-buffer " *asw-dedication-other*"))
           (session (agent-shell-window--make-session
                     :shell shell :active t :frame (selected-frame)
                     :root default-directory))
           (before (current-window-configuration))
           placeholder)
      (unwind-protect
          (let ((window (agent-shell-window--layout session t)))
            (setq placeholder (window-buffer window))
            (should (eq t (window-dedicated-p window)))
            (should-error (set-window-buffer window other))
            ;; The MCP layout path can still replace the displayed file.
            (setf (agent-shell-window--session-buffer session) other)
            (agent-shell-window--layout session nil)
            (should (eq other (window-buffer window)))
            (should (eq t (window-dedicated-p window))))
        (set-window-configuration before)
        (when (buffer-live-p placeholder) (kill-buffer placeholder))
        (kill-buffer other)
        (kill-buffer shell)))))
