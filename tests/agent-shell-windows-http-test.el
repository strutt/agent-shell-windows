;;; agent-shell-windows-http-test.el --- MCP display tests -*- lexical-binding: t; -*-
(require 'agent-shell-windows-http)
(require 'agent-shell-windows-panes-test)

(ert-deftest agent-shell-windows-http-complete-display-round-trip ()
  (agent-shell-windows-test--with-session
   (let* ((requests (agent-shell-windows-test--requests "one.el" "two.el"))
          (reply (agent-shell-windows-http--reply
                  session `((jsonrpc . "2.0") (id . 1) (method . "tools/call")
                            (params . ((name . "show_files")
                                       (arguments . ((panes . ,requests))))))))
          (result (alist-get 'result reply))
          (text (alist-get 'text (aref (alist-get 'content result) 0)))
          (view (json-parse-string text :object-type 'alist)))
     (should-not (alist-get 'isError result))
     (should (= 2 (length (alist-get 'panes view)))))
   (let* ((reply (agent-shell-windows-http--call-tool session '((name . "get_view"))))
          (view (json-parse-string
                 (alist-get 'text (aref (alist-get 'content reply) 0)) :object-type 'alist)))
     (should (= 2 (length (alist-get 'panes view)))))
   (should-error (agent-shell-windows-http--call-tool
                  session '((name . "get_view") (arguments . ((pane . 1))))))
   (let ((reply (agent-shell-windows-http--call-tool
                 session '((name . "show_files") (arguments . ((panes . [])))))))
     (should (alist-get 'isError reply)))))

(provide 'agent-shell-windows-http-test)

(ert-deftest agent-shell-windows-prepares-server-before-agent-start ()
  (let (events)
    (cl-letf (((symbol-function 'agent-shell-windows--ensure-server)
               (lambda () (push 'server events)))
              ((symbol-function 'agent-shell--start)
               (lambda (&rest _args) (push 'agent events) 'started)))
      (advice-add 'agent-shell--start :before #'agent-shell-windows--before-agent-start)
      (should (eq 'started (agent-shell--start :config nil)))
      (should (equal '(server agent) (reverse events))))))

(ert-deftest agent-shell-windows-server-failure-does-not-block-agent-start ()
  (let (warning)
    (cl-letf (((symbol-function 'agent-shell-windows--ensure-server)
               (lambda () (error "Address already in use")))
              ((symbol-function 'display-warning)
               (lambda (_type message &rest _) (setq warning message)))
              ((symbol-function 'agent-shell--start)
               (lambda (&rest _) 'started)))
      (advice-add 'agent-shell--start :before #'agent-shell-windows--before-agent-start)
      (should (eq 'started (agent-shell--start)))
      (should (string-match-p "Address already in use" warning)))))

(ert-deftest agent-shell-windows-server-start-is-idempotent ()
  (let ((agent-shell-windows-http--server nil)
        (agent-shell-windows-http-port 0)
        (agent-shell-windows-http-host "127.0.0.1"))
    (unwind-protect
        (progn
          (agent-shell-windows--before-agent-start)
          (let ((first agent-shell-windows-http--server))
            (should first)
            (should (process-live-p (ws-process first)))
            (agent-shell-windows--before-agent-start)
            (should (eq first agent-shell-windows-http--server))
            ;; Connection setup/reconnects share the same listener too.
            (agent-shell-windows--ensure-server)
            (should (eq first agent-shell-windows-http--server))))
      (when agent-shell-windows-http--server
        (delete-process (ws-process agent-shell-windows-http--server))))))
