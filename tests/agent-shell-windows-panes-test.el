;;; agent-shell-windows-panes-test.el --- Multiple pane regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'agent-shell-windows)

(defmacro agent-shell-windows-test--with-session (&rest body)
  "Run BODY with a visible session and two temporary files."
  (declare (indent 0))
  `(let* ((root (make-temp-file "asw-panes-" t))
          (shell (generate-new-buffer " *asw-panes-shell*"))
          (session (agent-shell-windows--make-session
                    :shell shell :root (file-name-as-directory root)
                    :active t :frame (selected-frame)))
          (agent-shell-windows--sessions (make-hash-table :test #'equal))
          (split-height-threshold nil)
          (split-width-threshold 0)
          (before (current-window-configuration))
          (width (frame-width)) (height (frame-height)))
     (puthash "test" session agent-shell-windows--sessions)
     (with-current-buffer shell (setq-local agent-shell-windows--session session))
     (when noninteractive (set-frame-size (selected-frame) 180 70))
     (unwind-protect
         (progn
           (dolist (name '("one.el" "two.el"))
             (with-temp-file (expand-file-name name root)
               (dotimes (index 120) (insert (format ";; Line %s\n" (1+ index))))))
           (agent-shell-windows--layout session t)
           ,@body)
       (set-window-configuration before)
       (dolist (pane (append (agent-shell-windows--session-panes session) nil))
         (mapc #'delete-overlay (agent-shell-windows--pane-overlays pane))
         (let ((buffer (agent-shell-windows--pane-buffer pane)))
           (when (buffer-live-p buffer) (kill-buffer buffer))))
       (dolist (buffer (buffer-list))
         (when (and (buffer-file-name buffer)
                    (file-in-directory-p (buffer-file-name buffer) root))
           (kill-buffer buffer)))
       (kill-buffer shell)
       (delete-directory root t)
       (when noninteractive (set-frame-size (selected-frame) width height)))))

(defun agent-shell-windows-test--show (session id file line)
  "Display FILE at LINE in SESSION's pane ID with one highlight."
  (agent-shell-windows--show-file
   session `((pane . ,id) (file . ,file)
             (highlights . [((start . [2 0]) (end . [3 0]))])
             (viewport . ((top_line . ,line))))))

(defun agent-shell-windows-test--file (session id)
  "Return the file name actually displayed in SESSION's pane ID."
  (file-name-nondirectory
   (buffer-file-name (window-buffer (agent-shell-windows--display-window session id)))))

(ert-deftest agent-shell-windows-pane-count-layouts ()
  (agent-shell-windows-test--with-session
   (let ((chat-edges (window-edges (agent-shell-windows--shell-window session))))
     (agent-shell-windows--set-panes session 2)
     (should (equal chat-edges (window-edges (agent-shell-windows--shell-window session))))
     (should (eq (window-parent (agent-shell-windows--display-window session 1))
                 (window-parent (agent-shell-windows--display-window session 2)))))
   (agent-shell-windows--set-panes session 3)
   (let ((chat (window-edges (agent-shell-windows--shell-window session)))
         (one (window-edges (agent-shell-windows--display-window session 1)))
         (two (window-edges (agent-shell-windows--display-window session 2)))
         (three (window-edges (agent-shell-windows--display-window session 3))))
     (should (= (nth 1 chat) (nth 1 one)))
     (should (= (nth 0 chat) (nth 0 two)))
     (should (= (nth 0 one) (nth 0 three)))
     (should (= (nth 1 two) (nth 1 three)))
     (should (<= (abs (- (- (nth 2 chat) (nth 0 chat))
                         (- (nth 2 one) (nth 0 one)))) 1))
     (should (<= (abs (- (- (nth 3 chat) (nth 1 chat))
                         (- (nth 3 two) (nth 1 two)))) 1)))
   (dolist (count '(2 1 3 1 2))
     (agent-shell-windows--set-panes session count)
     (should (= count (length (agent-shell-windows--windows session))))
     (dotimes (index count)
       (should (eq t (window-dedicated-p
                      (agent-shell-windows--display-window session (1+ index)))))))
   (should (eq (window-parent (agent-shell-windows--display-window session 1))
               (window-parent (agent-shell-windows--display-window session 2))))))

(ert-deftest agent-shell-windows-panes-have-independent-views ()
  (agent-shell-windows-test--with-session
   (agent-shell-windows--set-panes session 2)
   (let ((selected (selected-window)))
     (agent-shell-windows-test--show session 1 "one.el" 5)
     (let ((start (window-start (agent-shell-windows--display-window session 1))))
       (agent-shell-windows-test--show session 2 "one.el" 45)
       (should (= start (window-start (agent-shell-windows--display-window session 1)))))
     (should (eq selected (selected-window))))
   (let* ((one (agent-shell-windows--pane session 1))
          (two (agent-shell-windows--pane session 2)))
     (should (eq (agent-shell-windows--pane-buffer one) (agent-shell-windows--pane-buffer two)))
     (should-not (buffer-base-buffer (agent-shell-windows--pane-buffer one)))
     (should-not (eq (car (agent-shell-windows--pane-overlays one))
                     (car (agent-shell-windows--pane-overlays two))))
     (dolist (id '(1 2))
       (should (equal "one.el" (agent-shell-windows-test--file session id)))))
   (agent-shell-windows-test--show session 2 "two.el" 30)
   (should (equal "one.el" (agent-shell-windows-test--file session 1)))
   (should (equal "two.el" (agent-shell-windows-test--file session 2)))))

(ert-deftest agent-shell-windows-pane-validation ()
  (agent-shell-windows-test--with-session
   (dolist (count '(4 -1 1.5 "2" nil))
     (should-error (agent-shell-windows--set-panes session count)))
   (dolist (id '(0 2 4 -1 1.5 "1"))
     (should-error (agent-shell-windows--pane session id)))
   (should (= 1 (agent-shell-windows--pane-id (agent-shell-windows--pane session))))
   (setf (agent-shell-windows--session-active session) nil)
   (should-error (agent-shell-windows--set-panes session 2))
   (should-error (agent-shell-windows-test--show session 1 "one.el" 1))
   (should-not (agent-shell-windows--session-active session))))

(ert-deftest agent-shell-windows-hidden-panes-queue-separately ()
  (agent-shell-windows-test--with-session
   (agent-shell-windows--set-panes session 2)
   (agent-shell-windows--save session)
   (agent-shell-windows--remove-display session)
   (let ((away (generate-new-buffer " *asw-away*")))
     (unwind-protect
         (progn
           (switch-to-buffer away)
           (agent-shell-windows-test--show session 1 "one.el" 10)
           (agent-shell-windows-test--show session 2 "two.el" 40)
           (agent-shell-windows--set-panes session 3)
           (should (eq away (window-buffer (selected-window))))
           (should-not (agent-shell-windows--shell-window session))
           (agent-shell-windows--enter session (current-window-configuration) nil)
           (should (= 3 (length (agent-shell-windows--windows session))))
           (should (equal "one.el" (agent-shell-windows-test--file session 1)))
           (should (equal "two.el" (agent-shell-windows-test--file session 2))))
       (kill-buffer away)))))

(ert-deftest agent-shell-windows-pane-layout-rolls-back-on-small-frame ()
  (agent-shell-windows-test--with-session
   (agent-shell-windows-test--show session 1 "one.el" 12)
   (let ((split (symbol-function 'split-window)) (calls 0))
     (cl-letf (((symbol-function 'split-window)
                (lambda (&rest args)
                  (cl-incf calls)
                  (if (= calls 2) (error "Window too small") (apply split args)))))
       (should-error (agent-shell-windows--set-panes session 3))))
   (should (= 1 (agent-shell-windows--session-count session)))
   (should (= 1 (length (agent-shell-windows--windows session))))
   (should (equal "one.el" (agent-shell-windows-test--file session 1)))
   (let ((overlay (car (agent-shell-windows--pane-overlays (agent-shell-windows--pane session)))))
     (should (eq (overlay-get overlay 'window) (agent-shell-windows--display-window session))))))

(ert-deftest agent-shell-windows-shrinking-hides-removed-highlights ()
  (agent-shell-windows-test--with-session
   (agent-shell-windows--set-panes session 3)
   (agent-shell-windows-test--show session 3 "one.el" 10)
   (let ((overlay (car (agent-shell-windows--pane-overlays (agent-shell-windows--pane session 3)))))
     (agent-shell-windows--set-panes session 1)
     (should-not (overlay-buffer overlay))
     (should-error (agent-shell-windows--pane session 3))
     (should (buffer-live-p (find-buffer-visiting (expand-file-name "one.el" root)))))))

(defun agent-shell-windows-test--requests (&rest files)
  "Build a complete pane array for FILES."
  (vconcat
   (cl-loop for file in files for id from 1
            collect `((pane . ,id) (file . ,file) (highlights . [])
                      (viewport . ((top_line . ,(+ 1 (* 10 id)))))))))

(ert-deftest agent-shell-windows-show-panes-replaces-entire-display ()
  (agent-shell-windows-test--with-session
   (let ((selected (selected-window)))
     (agent-shell-windows--show-panes
      session `((panes . ,(agent-shell-windows-test--requests "one.el" "two.el" "one.el"))))
     (should (eq selected (selected-window))))
   (should (= 3 (length (agent-shell-windows--windows session))))
   (agent-shell-windows--show-panes
    session `((panes . ,(agent-shell-windows-test--requests "two.el"))))
   (should (equal "two.el" (agent-shell-windows-test--file session 1)))
   (should (= 1 (length (agent-shell-windows--windows session))))))

(ert-deftest agent-shell-windows-show-panes-empty-closes-and-can-reopen ()
  (agent-shell-windows-test--with-session
   (dolist (count '(1 2 3))
     (agent-shell-windows--set-panes session count)
     (agent-shell-windows-test--show session count "one.el" 10)
     (let ((overlay (car (agent-shell-windows--pane-overlays
                          (agent-shell-windows--pane session count))))
           (buffer (find-buffer-visiting (expand-file-name "one.el" root)))
           (chat (agent-shell-windows--shell-window session)))
       (dotimes (_ 2)
         (should (equal '((status . "visible") (panes . []))
                        (agent-shell-windows--show-panes session '((panes . []))))))
       (should (window-live-p chat))
       (should (eq (window-buffer chat) shell))
       (should-not (agent-shell-windows--windows session))
       (should-not (overlay-buffer overlay))
       (should (buffer-live-p buffer))
       (should (agent-shell-windows--session-active session))
       ;; Returning to the conversation must not resurrect cleared panes.
       (agent-shell-windows--enter session (current-window-configuration) nil)
       (should-not (agent-shell-windows--windows session)))
     (agent-shell-windows--show-panes
      session `((panes . ,(agent-shell-windows-test--requests "two.el"))))
     (should (equal "two.el" (agent-shell-windows-test--file session 1))))))

(ert-deftest agent-shell-windows-show-panes-empty-clears-hidden-display ()
  (agent-shell-windows-test--with-session
   (agent-shell-windows-test--show session 1 "one.el" 10)
   (agent-shell-windows--save session)
   (agent-shell-windows--remove-display session)
   (with-temp-buffer
     (switch-to-buffer (current-buffer))
     (let ((before (current-window-configuration)))
       (should (equal '((status . "hidden") (panes . []))
                      (agent-shell-windows--show-panes session '((panes . [])))))
       (should (compare-window-configurations before (current-window-configuration))))
     (agent-shell-windows--enter session (current-window-configuration) nil)
     (should-not (agent-shell-windows--windows session))
     (should (agent-shell-windows--shell-window session)))))

(ert-deftest agent-shell-windows-show-panes-empty-respects-stop ()
  (agent-shell-windows-test--with-session
   (setf (agent-shell-windows--session-active session) nil)
   (should-error (agent-shell-windows--show-panes session '((panes . []))))
   (should (= 1 (length (agent-shell-windows--windows session))))))

(ert-deftest agent-shell-windows-show-panes-validates-before-changing-display ()
  (agent-shell-windows-test--with-session
   (agent-shell-windows--show-panes
    session `((panes . ,(agent-shell-windows-test--requests "one.el"))))
   (dolist (requests (list nil
                           (agent-shell-windows-test--requests "two.el" "missing.el")
                           (agent-shell-windows-test--requests "two.el" "../outside.el")))
     (should-error (agent-shell-windows--show-panes session `((panes . ,requests))))
     (should (= 1 (agent-shell-windows--session-count session)))
     (should (equal "one.el" (agent-shell-windows-test--file session 1))))
   (let ((requests (agent-shell-windows-test--requests "one.el" "two.el")))
     (setf (alist-get 'pane (aref requests 1)) 1)
     (should-error (agent-shell-windows--show-panes session `((panes . ,requests)))))
   (let ((requests (agent-shell-windows-test--requests "one.el")))
     (setf (alist-get 'top_line (alist-get 'viewport (aref requests 0))) 0)
     (should-error (agent-shell-windows--show-panes session `((panes . ,requests)))))))

(ert-deftest agent-shell-windows-show-panes-hidden-display-is-one-snapshot ()
  (agent-shell-windows-test--with-session
   (agent-shell-windows--save session)
   (agent-shell-windows--remove-display session)
   (let ((away (generate-new-buffer " *asw-away-snapshot*")))
     (unwind-protect
         (progn
           (switch-to-buffer away)
           (agent-shell-windows--show-panes
            session `((panes . ,(agent-shell-windows-test--requests "one.el" "one.el" "one.el"))))
           (agent-shell-windows--show-panes
            session `((panes . ,(agent-shell-windows-test--requests "two.el" "one.el"))))
           (should (eq away (window-buffer (selected-window))))
           (should-not (agent-shell-windows--shell-window session))
           (agent-shell-windows--enter session (current-window-configuration) nil)
           (should (equal "two.el" (agent-shell-windows-test--file session 1)))
           (should (equal "one.el" (agent-shell-windows-test--file session 2)))
           (should (= 2 (length (agent-shell-windows--windows session)))))
       (kill-buffer away)))))

(ert-deftest agent-shell-windows-three-pane-layout-restores-after-close ()
  (agent-shell-windows-test--with-session
   (agent-shell-windows--show-panes
    session `((panes . ,(agent-shell-windows-test--requests "one.el" "two.el" "one.el"))))
   (agent-shell-windows--save session)
   (delete-window (agent-shell-windows--display-window session 2))
   (should-not (agent-shell-windows--display-window session 2))
   (agent-shell-windows--switch-buffer (lambda () (switch-to-buffer shell)))
   (should (= 3 (length (agent-shell-windows--windows session))))
   (should (equal "two.el" (agent-shell-windows-test--file session 2)))))


(ert-deftest agent-shell-windows-switch-from-dedicated-pane ()
  (agent-shell-windows-test--with-session
   (agent-shell-windows--show-panes
    session `((panes . ,(agent-shell-windows-test--requests "one.el" "two.el"))))
   (select-window (agent-shell-windows--display-window session 2))
   (agent-shell-windows--switch-buffer (lambda () (switch-to-buffer shell)))
   (should (= 2 (length (agent-shell-windows--windows session))))))

(ert-deftest agent-shell-windows-session-panes-restore-independently ()
  (agent-shell-windows-test--with-session
   (agent-shell-windows--show-panes
    session `((panes . ,(agent-shell-windows-test--requests "one.el" "two.el"))))
   (let* ((shell-two (generate-new-buffer " *asw-second-session*"))
          (second (agent-shell-windows--make-session
                   :shell shell-two :root (file-name-as-directory root)
                   :active t :frame (selected-frame))))
     (unwind-protect
         (progn
           (puthash "second" second agent-shell-windows--sessions)
           (with-current-buffer shell-two (setq-local agent-shell-windows--session second))
           (agent-shell-windows--save session)
           (agent-shell-windows--layout second t)
           (agent-shell-windows--show-panes
            second `((panes . ,(agent-shell-windows-test--requests "two.el" "one.el" "two.el"))))
           (agent-shell-windows--save second)
           (agent-shell-windows--enter session (current-window-configuration) second)
           (should (= 2 (length (agent-shell-windows--windows session))))
           (should-not (agent-shell-windows--windows second))
           (should (equal "one.el" (agent-shell-windows-test--file session 1)))
           (agent-shell-windows--enter second (current-window-configuration) session)
           (should (= 3 (length (agent-shell-windows--windows second))))
           (should-not (agent-shell-windows--windows session))
           (should (equal "two.el" (agent-shell-windows-test--file second 1))))
       (mapc (lambda (pane) (mapc #'delete-overlay (agent-shell-windows--pane-overlays pane)))
             (agent-shell-windows--session-panes second))
       (kill-buffer shell-two)))))

(ert-deftest agent-shell-windows-one-pane-respects-emacs-split-heuristic ()
  (agent-shell-windows-test--with-session
    (let ((split-height-threshold 0) (split-width-threshold nil))
      (agent-shell-windows--layout session t))
    (let ((chat (window-edges (agent-shell-windows--shell-window session)))
          (file (window-edges (agent-shell-windows--display-window session))))
      (should (= (nth 0 chat) (nth 0 file)))
      (should (= (nth 2 chat) (nth 2 file)))
      (should (= (nth 3 chat) (nth 1 file))))))

(provide 'agent-shell-windows-panes-test)

(ert-deftest agent-shell-windows-show-panes-returns-visible-line-ranges ()
  (agent-shell-windows-test--with-session
   (let* ((result (agent-shell-windows--show-panes
                   session `((panes . ,(agent-shell-windows-test--requests "one.el" "two.el")))))
          (panes (alist-get 'panes result)))
     (should (equal "visible" (alist-get 'status result)))
     (should (= 2 (length panes)))
     (dotimes (index 2)
       (let* ((pane (aref panes index))
              (viewport (alist-get 'viewport pane)))
         (should (= (1+ index) (alist-get 'pane pane)))
         (should (= (+ 1 (* 10 (1+ index))) (alist-get 'top_line viewport)))
         (should (> (alist-get 'bottom_line viewport) (alist-get 'top_line viewport)))
         (should (<= (alist-get 'bottom_line viewport) 120)))))
   ;; The last visible line is inclusive; the trailing newline adds no line.
   (with-temp-file (expand-file-name "short.el" root) (insert "one\ntwo\n"))
   (let* ((result (agent-shell-windows--show-panes
                   session '((panes . [((pane . 1) (file . "short.el")
                                        (highlights . []) (viewport . ((top_line . 1))))]))))
          (viewport (alist-get 'viewport (aref (alist-get 'panes result) 0))))
     (should (equal '((top_line . 1) (bottom_line . 2)) viewport)))))

(ert-deftest agent-shell-windows-show-panes-hidden-response ()
  (agent-shell-windows-test--with-session
   (agent-shell-windows--remove-display session)
   (switch-to-buffer (get-buffer-create " *asw-hidden-response*"))
   (unwind-protect
       (let ((result (agent-shell-windows--show-panes
                      session `((panes . ,(agent-shell-windows-test--requests "one.el" "two.el"))))))
         (should (equal '((status . "hidden") (panes . [((pane . 1)) ((pane . 2))])) result))
         (should-not (agent-shell-windows--windows session)))
     (kill-buffer " *asw-hidden-response*"))))
