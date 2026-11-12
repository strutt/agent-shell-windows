;;; agent-shell-window-http.el --- HTTP MCP for agent-shell-window -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (web-server "0.1.2"))

;;; Commentary:

;; A shared, stateless HTTP MCP endpoint.  Each connection carries its
;; agent-shell routing ID in the X-Agent-Shell-Window-Session header.

;;; Code:

(require 'agent-shell-window)
(require 'json)
(require 'web-server)

(defcustom agent-shell-window-http-host "127.0.0.1"
  "Address on which the shared HTTP server listens."
  :type 'string
  :group 'agent-shell-window)

(defcustom agent-shell-window-http-port 8765
  "Port on which the shared HTTP server listens."
  :type 'natnum
  :group 'agent-shell-window)

(defvar agent-shell-window-http--server nil)
(defconst agent-shell-window-http--versions '("2025-06-18" "2025-03-26"))
(define-error 'agent-shell-window-http--rpc-error "Window MCP protocol error")

(defconst agent-shell-window-http--tools
  (let ((position '((type . "array") (minItems . 2) (maxItems . 2)
                    (items . ((type . "integer") (minimum . 0)))
                    (description . "[line, column]: line starts at 1, column at 0. Columns count characters; a tab is one character."))))
    `[((name . "show_file")
       (description . "Display a file beside this conversation. Supply the relative file path, all highlight ranges, and the first visible line. Ranges have exclusive ends. Use [] for no highlights. Viewport and highlights are independent. Returns the current view or hidden status.")
       (inputSchema .
                    ((type . "object")
                     (properties .
                                 ((file . ((type . "string") (minLength . 1)
                                           (description . "Path relative to this session's working directory.")))
                                  (highlights .
                                              ((type . "array")
                                               (items . ((type . "object")
                                                         (properties . ((start . ,position) (end . ,position)))
                                                         (required . ["start" "end"])
                                                         (additionalProperties . :json-false)))))
                                  (viewport . ((type . "object")
                                               (properties . ((top_line . ((type . "integer") (minimum . 1)))))
                                               (required . ["top_line"])
                                               (additionalProperties . :json-false)))))
                     (required . ["file" "highlights" "viewport"])
                     (additionalProperties . :json-false)))
       (annotations . ((destructiveHint . :json-false) (openWorldHint . :json-false))))
      ((name . "get_view")
       (description . "Read this conversation's actual file view, including visible live text, unsaved status, mode, cursor, and highlights. Reports hidden, closed, or stopped when applicable. Use after the user scrolls or edits.")
       (inputSchema . ((type . "object") (additionalProperties . :json-false)))
       (annotations . ((readOnlyHint . t) (openWorldHint . :json-false))))]))

(defun agent-shell-window-http--json (value)
  "Encode VALUE with the package's JSON boolean convention."
  (let ((json-false :json-false) (json-null nil))
    (json-encode value)))

(defun agent-shell-window-http--object-p (value)
  "Return non-nil when VALUE represents a JSON object alist."
  (and (listp value)
       (cl-every (lambda (entry) (and (consp entry) (symbolp (car entry)))) value)))

(defun agent-shell-window-http--invalid (message)
  "Signal invalid MCP parameters with MESSAGE."
  (signal 'agent-shell-window-http--rpc-error (list -32602 message)))

(defun agent-shell-window-http--call-tool (session params)
  "Call the file-viewing tool in PARAMS for SESSION."
  (let* ((name (alist-get 'name params))
         (tool (cl-find-if (lambda (item) (equal name (alist-get 'name item)))
                           (append agent-shell-window-http--tools nil)))
         (arguments (alist-get 'arguments params))
         (schema (alist-get 'inputSchema tool)))
    (unless tool (agent-shell-window-http--invalid "Unknown tool"))
    (unless (agent-shell-window-http--object-p arguments)
      (agent-shell-window-http--invalid "arguments must be an object"))
    (dolist (entry arguments)
      (unless (assq (car entry) (alist-get 'properties schema))
        (agent-shell-window-http--invalid (format "Unknown argument: %s" (car entry)))))
    (mapc
     (lambda (key)
       (unless (assq (intern key) arguments)
         (agent-shell-window-http--invalid (format "Missing argument: %s" key))))
     (alist-get 'required schema))
    (condition-case err
        (let ((result
               (pcase name
                 ("show_file" (agent-shell-window--show-file session arguments))
                 ("get_view" (agent-shell-window--get-view session)))))
          `((content . [((type . "text")
                         (text . ,(agent-shell-window-http--json result)))])))
      ((error quit)
       `((isError . t)
         (content . [((type . "text") (text . ,(error-message-string err)))]))))))

(defun agent-shell-window-http--dispatch (session method params)
  "Handle MCP METHOD with PARAMS for SESSION."
  (pcase method
    ("initialize"
     (unless (stringp (alist-get 'protocolVersion params))
       (agent-shell-window-http--invalid "initialize requires protocolVersion"))
     `((protocolVersion . ,(if (member (alist-get 'protocolVersion params)
                                      agent-shell-window-http--versions)
                              (alist-get 'protocolVersion params)
                            (car agent-shell-window-http--versions)))
       (capabilities . ((tools . ((listChanged . :json-false)))))
       (serverInfo . ((name . "agent-shell-window") (version . "0.1.0")))
       (instructions . ,(concat
                          "Use show_file to display a file for this conversation. "
                          "All paths are relative to the associated shell's working directory. "
                          "Always supply file, highlights, and viewport.top_line. "
                          "Highlight endpoints are [line, character], starting at [1, 0], with exclusive ends. "
                          "Use an empty highlight array to clear highlights. "
                          "Emacs chooses the file's mode. Create files with your normal file tools. "
                          "Use get_view to read visible live text after navigation or edits. "
                          "Hidden sessions retain their latest request until the user returns. "
                          "The user controls viewing with agent-shell-window-start and agent-shell-window-stop in Emacs."))))
    ("ping" (make-hash-table :test #'equal))
    ("tools/list" (list (cons 'tools agent-shell-window-http--tools)))
    ("tools/call" (agent-shell-window-http--call-tool session params))
    (_ (signal 'agent-shell-window-http--rpc-error (list -32601 "Method not found")))))

(defun agent-shell-window-http--error (id code message)
  "Construct a JSON-RPC error for ID with CODE and MESSAGE."
  `((jsonrpc . "2.0") (id . ,id) (error . ((code . ,code) (message . ,message)))))

(defun agent-shell-window-http--reply (session request)
  "Return SESSION's JSON-RPC response to REQUEST, or nil for a notification."
  (let* ((object-p (agent-shell-window-http--object-p request))
         (id (and object-p (alist-get 'id request))))
    (unless (or (stringp id) (integerp id)) (setq id nil))
    (condition-case err
        (progn
          (unless (and object-p (equal (alist-get 'jsonrpc request) "2.0"))
            (signal 'agent-shell-window-http--rpc-error (list -32600 "Invalid JSON-RPC request")))
          (let ((method (alist-get 'method request))
                (params (alist-get 'params request))
                (has-id (assq 'id request)))
            (cond
             ((and (null method) has-id (or (assq 'result request) (assq 'error request))) nil)
             ((not (and (stringp method) (agent-shell-window-http--object-p params)))
              (signal 'agent-shell-window-http--rpc-error (list -32600 "Invalid method or params")))
             ((not has-id)
              (unless (string-prefix-p "notifications/" method)
                (signal 'agent-shell-window-http--rpc-error (list -32600 "MCP requests require an id")))
              nil)
             ((null id)
              (signal 'agent-shell-window-http--rpc-error (list -32600 "id must be a string or integer")))
             (t
              `((jsonrpc . "2.0") (id . ,id)
                (result . ,(agent-shell-window-http--dispatch session method params)))))))
      (agent-shell-window-http--rpc-error
       (agent-shell-window-http--error id (nth 1 err) (nth 2 err)))
      ((error quit)
       (agent-shell-window-http--error id -32603 (error-message-string err))))))

(defun agent-shell-window-http--send (request status body &optional headers)
  "Respond to REQUEST with STATUS, JSON BODY, and optional HEADERS."
  (let* ((process (ws-process request))
         (bytes (if body
                    (encode-coding-string (agent-shell-window-http--json body) 'utf-8 t)
                  "")))
    (apply #'ws-response-header process status
           (append `(("Content-Type" . "application/json; charset=utf-8")
                     ("Content-Length" . ,(number-to-string (string-bytes bytes)))
                     ("Cache-Control" . "no-store") ("Connection" . "close"))
                   headers))
    (unless (string-empty-p bytes) (ws-send process bytes))
    (throw 'close-connection nil)))

(defun agent-shell-window-http--handle (request)
  "Handle a web-server REQUEST, containing failures to this request."
  (condition-case err
      (let* ((headers (ws-headers request))
             (route (cl-find-if
                     (lambda (entry) (memq (car entry) '(:POST :GET :DELETE :HEAD :PUT :PATCH :OPTIONS :TRACE)))
                     headers))
             (version (cdr (assq :MCP-PROTOCOL-VERSION headers)))
             (content-type (cdr (assq :CONTENT-TYPE headers)))
             (session (gethash (cdr (assq :X-AGENT-SHELL-WINDOW-SESSION headers))
                               agent-shell-window--sessions)))
        (cond
         ((assq :ORIGIN headers)
          (agent-shell-window-http--send request 403 '((error . "Browser origins are disabled"))))
         ((not (equal (cdr route) "/mcp"))
          (agent-shell-window-http--send request 404 '((error . "Unknown endpoint"))))
         ((not (eq (car route) :POST))
          (agent-shell-window-http--send request 405 '((error . "Use POST")) '(("Allow" . "POST"))))
         ((not (and session (buffer-live-p (agent-shell-window--session-shell session))))
          (agent-shell-window-http--send request 403 '((error . "Unknown agent-shell connection"))))
         ((and version (not (member version agent-shell-window-http--versions)))
          (agent-shell-window-http--send request 400 '((error . "Unsupported MCP-Protocol-Version"))))
         ((not (and (stringp content-type)
                    (string-prefix-p "application/json" (downcase content-type))))
          (agent-shell-window-http--send request 415 '((error . "Use application/json"))))
         (t
          (let ((reply
                 (condition-case nil
                     (agent-shell-window-http--reply
                      session (json-parse-string
                               (decode-coding-string (ws-body request) 'utf-8)
                               :object-type 'alist :array-type 'array
                               :null-object :json-null :false-object :json-false))
                   (json-error (agent-shell-window-http--error nil -32700 "Invalid JSON")))))
            (agent-shell-window-http--send request (if reply 200 202) reply)))))
    ((error quit)
     (agent-shell-window-http--send
      request 500 (agent-shell-window-http--error nil -32603 (error-message-string err))))))

(defun agent-shell-window-http--reject (process status message)
  "Reject one HTTP request on PROCESS with STATUS and MESSAGE."
  (catch 'close-connection
    (agent-shell-window-http--send
     (make-instance 'ws-request :process process) status (list (cons 'error message))))
  (delete-process process))

(defun agent-shell-window-http--receive (process chunk)
  "Accumulate a complete request from CHUNK on PROCESS before dispatch.
web-server 0.1.2 may dispatch before the body has arrived."
  (let* ((pending (concat (process-get process 'agent-shell-window-pending) chunk))
         (boundary (string-match "\r\n\r\n" pending)))
    (cond
     ((and (not boundary) (> (string-bytes pending) 16384))
      (agent-shell-window-http--reject process 413 "Request headers exceed 16384 bytes"))
     ((not boundary) (process-put process 'agent-shell-window-pending pending))
     ((> boundary 16384)
      (agent-shell-window-http--reject process 413 "Request headers exceed 16384 bytes"))
     (t
      (let* ((headers (substring pending 0 (+ boundary 2)))
             (case-fold-search t) (index 0) lengths)
        (while (string-match "^Content-Length:[ \t]*\\([0-9]+\\)[ \t]*\r?$" headers index)
          (push (string-to-number (match-string 1 headers)) lengths)
          (setq index (match-end 0)))
        (cond
         ((string-match-p "^Transfer-Encoding:" headers)
          (agent-shell-window-http--reject process 501 "Send JSON with Content-Length"))
         ((> (length lengths) 1)
          (agent-shell-window-http--reject process 400 "Use one Content-Length header"))
         ((and (null lengths) (string-prefix-p "POST " headers))
          (agent-shell-window-http--reject process 411 "POST requires Content-Length"))
         ((> (or (car lengths) 0) 1000000)
          (agent-shell-window-http--reject process 413 "Request exceeds 1000000 bytes"))
         (t
          (let ((total (+ boundary 4 (or (car lengths) 0))))
            (if (< (string-bytes pending) total)
                (process-put process 'agent-shell-window-pending pending)
              (process-put process 'agent-shell-window-pending nil)
              (ws-filter process (substring pending 0 total)))))))))))

(defun agent-shell-window-http--filter (process chunk)
  "Handle CHUNK on PROCESS while keeping the shared listener running."
  (condition-case err
      (agent-shell-window-http--receive process chunk)
    ((error quit)
     (ignore-errors
       (agent-shell-window-http--reject process 500 (error-message-string err))))))

(defun agent-shell-window-http--ensure ()
  "Start or reuse the shared HTTP MCP listener."
  (unless (and agent-shell-window-http--server
               (process-live-p (ws-process agent-shell-window-http--server)))
    (setq agent-shell-window-http--server
          (ws-start #'agent-shell-window-http--handle
                    agent-shell-window-http-port nil :host agent-shell-window-http-host))
    (set-process-filter (ws-process agent-shell-window-http--server)
                        #'agent-shell-window-http--filter))
  agent-shell-window-http--server)

(provide 'agent-shell-window-http)
;;; agent-shell-window-http.el ends here
