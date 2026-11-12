;;; agent-shell-windows-test.el --- Layout regression tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'agent-shell-windows)
(ert-deftest agent-shell-windows-restores-collapsed-pair ()
  (let ((split-height-threshold nil) (split-width-threshold 0))
    (save-window-excursion
      (let* ((shell (generate-new-buffer " *asw-test-shell*"))
             (session (agent-shell-windows--make-session
                       :shell shell :active t :frame (selected-frame)
                       :root default-directory))
             (before (current-window-configuration))
             (agent-shell-windows--sessions (make-hash-table :test #'equal)))
	(puthash "test" session agent-shell-windows--sessions)
	(with-current-buffer shell (setq-local agent-shell-windows--session session))
	(unwind-protect
            (progn
              (agent-shell-windows--layout session t)
              (let ((view (agent-shell-windows--display-window session)))
		(window-resize view -7 t)
		(agent-shell-windows--save session)
		(let ((width (window-total-width view)))
                  (delete-window view)
                  (agent-shell-windows--switch-buffer (lambda () (switch-to-buffer shell)))
                  (should (agent-shell-windows--display-window session))
                  (should (= width (window-total-width (agent-shell-windows--display-window session)))))))
          (set-window-configuration before)
          (when (buffer-live-p (agent-shell-windows--pane-buffer (agent-shell-windows--pane session)))
            (kill-buffer (agent-shell-windows--pane-buffer (agent-shell-windows--pane session))))
          (kill-buffer shell))))))

(ert-deftest agent-shell-windows-uses-normal-file-buffer ()
  (let* ((file (make-temp-file "agent-shell-windows-test-" nil ".el" ";;; Example\n"))
         (session (agent-shell-windows--make-session))
         (base (find-file-noselect file)))
    (unwind-protect
        (progn
          (should (eq base (agent-shell-windows--file-buffer session file)))
          (with-current-buffer base
            (should auto-revert-mode)
            (with-temp-file file (insert ";;; Changed by agent\n"))
            (set-file-times file (time-add (current-time) 2))
            (auto-revert-handler)
            (should (equal ";;; Changed by agent\n" (buffer-string))))
          (should-not (buffer-base-buffer (agent-shell-windows--pane-buffer (agent-shell-windows--pane session))))
          (with-current-buffer base
            (goto-char (point-max))
            (insert ";; Unsaved edit\n"))
          (should (eq base (agent-shell-windows--file-buffer session file)))
          (should (buffer-modified-p base)))
      (with-current-buffer base (set-buffer-modified-p nil))
      (kill-buffer base)
      (delete-file file))))

(ert-deftest agent-shell-windows-dedicates-file-pane ()
  (let ((split-height-threshold nil) (split-width-threshold 0))
    (save-window-excursion
      (let* ((shell (generate-new-buffer " *asw-dedication-shell*"))
             (other (generate-new-buffer " *asw-dedication-other*"))
             (session (agent-shell-windows--make-session
                       :shell shell :active t :frame (selected-frame)
                       :root default-directory))
             (before (current-window-configuration))
             placeholder)
	(unwind-protect
            (let ((window (agent-shell-windows--layout session t)))
              (setq placeholder (window-buffer window))
              (should (eq t (window-dedicated-p window)))
              (should-error (set-window-buffer window other))
              ;; The MCP layout path can still replace the displayed file.
              (setf (agent-shell-windows--pane-buffer (agent-shell-windows--pane session)) other)
              (agent-shell-windows--layout session nil)
              (should (eq other (window-buffer window)))
              (should (eq t (window-dedicated-p window))))
          (set-window-configuration before)
          (when (buffer-live-p placeholder) (kill-buffer placeholder))
          (kill-buffer other)
          (kill-buffer shell))))))

(ert-deftest agent-shell-windows-start-without-panes-preserves-frame ()
  (save-window-excursion
    (let ((agent-shell-windows--sessions (make-hash-table :test #'equal)))
      (with-temp-buffer
        (setq major-mode 'agent-shell-mode)
        (delete-other-windows)
        (split-window-right)
        (let ((before (current-window-configuration)))
          (cl-letf (((symbol-function 'agent-shell-windows--ensure-server) #'ignore))
            (let ((session (agent-shell-windows-start)))
              (should (agent-shell-windows--session-active session))
              (should (compare-window-configurations before (current-window-configuration)))
              (should-not (agent-shell-windows--windows session))
              (agent-shell-windows-start)
              (should (compare-window-configurations before (current-window-configuration))))))))))

(ert-deftest agent-shell-windows-first-request-creates-display ()
  (save-window-excursion
    (let* ((agent-shell-windows--sessions (make-hash-table :test #'equal))
           (file (make-temp-file "asw-first-request-" nil ".el" ";; First request\n"))
           (default-directory (file-name-directory file))
           (split-height-threshold nil)
           (split-width-threshold 0))
      (unwind-protect
          (with-temp-buffer
            (setq major-mode 'agent-shell-mode)
            (switch-to-buffer (current-buffer))
            (cl-letf (((symbol-function 'agent-shell-windows--ensure-server) #'ignore))
              (let ((session (agent-shell-windows-start))
                    (before (current-window-configuration)))
                ;; Allocating pane state must not request a display.
                (agent-shell-windows--pane session)
                (agent-shell-windows-start)
                (agent-shell-windows--switch-buffer (lambda () (current-buffer)))
                (agent-shell-windows--display-buffer (lambda (_) (selected-window))
                                                   (current-buffer))
                (should (compare-window-configurations before (current-window-configuration)))
                (agent-shell-windows--show-files
                 session `((panes . [((pane . 1)
                                      (file . ,(file-name-nondirectory file))
                                      (highlights . [])
                                      (viewport . ((top_line . 1))))])))
                (should (= 1 (length (agent-shell-windows--windows session))))
                (should (equal (file-name-nondirectory file)
                               (file-name-nondirectory
                                (buffer-file-name
                                 (window-buffer (agent-shell-windows--display-window session)))))))))
        (when-let* ((buffer (find-buffer-visiting file))) (kill-buffer buffer))
        (delete-file file)))))
