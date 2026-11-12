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
