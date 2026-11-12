;;; agent-shell-windows-http.el --- HTTP MCP for agent-shell-windows -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (web-server "0.1.2"))

;;; Commentary:

;; A shared, stateless HTTP MCP endpoint.  Each connection carries its
;; agent-shell routing ID in the X-Agent-Shell-Windows-Session header.

;;; Code:

(require 'agent-shell-windows)
(require 'json)
(require 'web-server)

(defcustom agent-shell-windows-http-host "127.0.0.1"
  "Address on which the shared HTTP server listens."
  :type 'string
  :group 'agent-shell-windows)

(defcustom agent-shell-windows-http-port 8765
  "Port on which the shared HTTP server listens."
  :type 'natnum
  :group 'agent-shell-windows)

(defvar agent-shell-windows-http--server nil)
(defconst agent-shell-windows-http--versions '("2025-06-18" "2025-03-26"))
(define-error 'agent-shell-windows-http--rpc-error "Window MCP protocol error")

(defconst agent-shell-windows-http--tools
  (let* ((position '((type . "array") (minItems . 2) (maxItems . 2)
                     (items . ((type . "integer") (minimum . 0)))
                     (description . "[line, column]: line starts at 1, column at 0. Columns count characters; a tab is one character.")))
         (pane `((type . "object")
                 (properties .
                             ((pane . ((type . "integer") (minimum . 1) (maximum . 3)))
                              (file . ((type . "string") (minLength . 1)
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
                 (required . ["pane" "file" "highlights" "viewport"])
                 (additionalProperties . :json-false))))
    `[((name . "show_files")
       (description . "Replace this conversation's entire file display in one call. Supply 1 to 3 complete panes, ordered and numbered 1, 2, 3. Each call specifies every file, all highlights, and viewport.top_line; omitted panes close. Emacs chooses layout: 1 standard split; 2 subdivides the file area; 3 a 2×2 grid with chat. Use [] to clear a pane's highlights. Hidden sessions retain the latest complete display until you return. Returns all pane views. Cannot activate a stopped session.")
       (inputSchema . ((type . "object")
                       (properties . ((panes . ((type . "array") (minItems . 1) (maxItems . 3)
                                                (items . ,pane)))))
                       (required . ["panes"])
                       (additionalProperties . :json-false)))
       (annotations . ((destructiveHint . :json-false) (openWorldHint . :json-false))))
      ((name . "get_view")
       (description . "Read every configured pane of this conversation, including actual visible live text, unsaved status, mode, cursor, and highlights. Reports empty, hidden, closed, or stopped per pane. Use after the user scrolls or edits. Does not reveal hidden sessions or recreate closed panes.")
       (inputSchema . ((type . "object") (additionalProperties . :json-false)))
       (annotations . ((readOnlyHint . t) (openWorldHint . :json-false))))]))

(defun agent-shell-windows-http--json (value)
  "Encode VALUE with the package's JSON boolean convention."
  (let ((json-false :json-false) (json-null nil))
    (json-encode value)))

(defun agent-shell-windows-http--object-p (value)
  "Return non-nil when VALUE represents a JSON object alist."
  (and (listp value)
       (cl-every (lambda (entry) (and (consp entry) (symbolp (car entry)))) value)))

(defun agent-shell-windows-http--invalid (message)
  "Signal invalid MCP parameters with MESSAGE."
  (signal 'agent-shell-windows-http--rpc-error (list -32602 message)))

(defun agent-shell-windows-http--call-tool (session params)
  "Call the file-viewing tool in PARAMS for SESSION."
  (let* ((name (alist-get 'name params))
         (tool (cl-find-if (lambda (item) (equal name (alist-get 'name item)))
                           (append agent-shell-windows-http--tools nil)))
         (arguments (alist-get 'arguments params))
         (schema (alist-get 'inputSchema tool)))
    (unless tool (agent-shell-windows-http--invalid "Unknown tool"))
    (unless (agent-shell-windows-http--object-p arguments)
      (agent-shell-windows-http--invalid "arguments must be an object"))
    (dolist (entry arguments)
      (unless (assq (car entry) (alist-get 'properties schema))
        (agent-shell-windows-http--invalid (format "Unknown argument: %s" (car entry)))))
    (mapc
     (lambda (key)
       (unless (assq (intern key) arguments)
         (agent-shell-windows-http--invalid (format "Missing argument: %s" key))))
     (alist-get 'required schema))
    (condition-case err
        (let ((result
               (pcase name
                 ("show_files" (agent-shell-windows--show-files session arguments))
                 ("get_view" (agent-shell-windows--get-views session)))))
          `((content . [((type . "text")
                         (text . ,(agent-shell-windows-http--json result)))])))
      ((error quit)
       `((isError . t)
         (content . [((type . "text") (text . ,(error-message-string err)))]))))))

(defun agent-shell-windows-http--dispatch (session method params)
  "Handle MCP METHOD with PARAMS for SESSION."
  (pcase method
    ("initialize"
     (unless (stringp (alist-get 'protocolVersion params))
       (agent-shell-windows-http--invalid "initialize requires protocolVersion"))
     `((protocolVersion . ,(if (member (alist-get 'protocolVersion params)
                                       agent-shell-windows-http--versions)
                               (alist-get 'protocolVersion params)
                             (car agent-shell-windows-http--versions)))
       (capabilities . ((tools . ((listChanged . :json-false)))))
       (serverInfo . ((name . "agent-shell-windows") (version . "0.1.0")))
       (instructions . ,(concat
                         "Use show_files to specify this conversation's entire file display in one call. "
                         "Always supply a panes array of 1 to 3 complete entries, ordered and numbered 1, 2, 3. "
                         "Each entry supplies pane, file, highlights, and viewport.top_line; omitted panes close. "
                         "Emacs chooses the layout from the count. No separate pane setup is needed. "
                         "All paths are relative to the associated shell's working directory. "
                         "Highlight endpoints are [line, character], starting at [1, 0], with exclusive ends. "
                         "Use an empty highlight array to clear highlights. "
                         "Emacs chooses the file's mode. Create files with your normal file tools. "
                         "Use get_view with no arguments to read all panes' visible live text after navigation or edits. "
                         "Hidden sessions retain the latest complete display until the user returns. "
                         "The user controls viewing with agent-shell-windows-start and agent-shell-windows-stop in Emacs."))))
    ("ping" (make-hash-table :test #'equal))
    ("tools/list" (list (cons 'tools agent-shell-windows-http--tools)))
    ("tools/call" (agent-shell-windows-http--call-tool session params))
    (_ (signal 'agent-shell-windows-http--rpc-error (list -32601 "Method not found")))))

(defun agent-shell-windows-http--error (id code message)
  "Construct a JSON-RPC error for ID with CODE and MESSAGE."
  `((jsonrpc . "2.0") (id . ,id) (error . ((code . ,code) (message . ,message)))))

(defun agent-shell-windows-http--reply (session request)
  "Return SESSION's JSON-RPC response to REQUEST, or nil for a notification."
  (let* ((object-p (agent-shell-windows-http--object-p request))
         (id (and object-p (alist-get 'id request))))
    (unless (or (stringp id) (integerp id)) (setq id nil))
    (condition-case err
        (progn
          (unless (and object-p (equal (alist-get 'jsonrpc request) "2.0"))
            (signal 'agent-shell-windows-http--rpc-error (list -32600 "Invalid JSON-RPC request")))
          (let ((method (alist-get 'method request))
                (params (alist-get 'params request))
                (has-id (assq 'id request)))
            (cond
             ((and (null method) has-id (or (assq 'result request) (assq 'error request))) nil)
             ((not (and (stringp method) (agent-shell-windows-http--object-p params)))
              (signal 'agent-shell-windows-http--rpc-error (list -32600 "Invalid method or params")))
             ((not has-id)
              (unless (string-prefix-p "notifications/" method)
                (signal 'agent-shell-windows-http--rpc-error (list -32600 "MCP requests require an id")))
              nil)
             ((null id)
              (signal 'agent-shell-windows-http--rpc-error (list -32600 "id must be a string or integer")))
             (t
              `((jsonrpc . "2.0") (id . ,id)
                (result . ,(agent-shell-windows-http--dispatch session method params)))))))
      (agent-shell-windows-http--rpc-error
       (agent-shell-windows-http--error id (nth 1 err) (nth 2 err)))
      ((error quit)
       (agent-shell-windows-http--error id -32603 (error-message-string err))))))

(defun agent-shell-windows-http--send (request status body &optional headers)
  "Respond to REQUEST with STATUS, JSON BODY, and optional HEADERS."
  (let* ((process (ws-process request))
         (bytes (if body
                    (encode-coding-string (agent-shell-windows-http--json body) 'utf-8 t)
                  "")))
    (apply #'ws-response-header process status
           (append `(("Content-Type" . "application/json; charset=utf-8")
                     ("Content-Length" . ,(number-to-string (string-bytes bytes)))
                     ("Cache-Control" . "no-store") ("Connection" . "close"))
                   headers))
    (unless (string-empty-p bytes) (ws-send process bytes))
    (throw 'close-connection nil)))

(defun agent-shell-windows-http--handle (request)
  "Handle a web-server REQUEST, containing failures to this request."
  (condition-case err
      (let* ((headers (ws-headers request))
             (route (cl-find-if
                     (lambda (entry) (memq (car entry) '(:POST :GET :DELETE :HEAD :PUT :PATCH :OPTIONS :TRACE)))
                     headers))
             (version (cdr (assq :MCP-PROTOCOL-VERSION headers)))
             (content-type (cdr (assq :CONTENT-TYPE headers)))
             (session (gethash (cdr (assq :X-AGENT-SHELL-WINDOWS-SESSION headers))
                               agent-shell-windows--sessions)))
        (cond
         ((assq :ORIGIN headers)
          (agent-shell-windows-http--send request 403 '((error . "Browser origins are disabled"))))
         ((not (equal (cdr route) "/mcp"))
          (agent-shell-windows-http--send request 404 '((error . "Unknown endpoint"))))
         ((not (eq (car route) :POST))
          (agent-shell-windows-http--send request 405 '((error . "Use POST")) '(("Allow" . "POST"))))
         ((not (and session (buffer-live-p (agent-shell-windows--session-shell session))))
          (agent-shell-windows-http--send request 403 '((error . "Unknown agent-shell connection"))))
         ((and version (not (member version agent-shell-windows-http--versions)))
          (agent-shell-windows-http--send request 400 '((error . "Unsupported MCP-Protocol-Version"))))
         ((not (and (stringp content-type)
                    (string-prefix-p "application/json" (downcase content-type))))
          (agent-shell-windows-http--send request 415 '((error . "Use application/json"))))
         (t
          (let ((reply
                 (condition-case nil
                     (agent-shell-windows-http--reply
                      session (json-parse-string
                               (decode-coding-string (ws-body request) 'utf-8)
                               :object-type 'alist :array-type 'array
                               :null-object :json-null :false-object :json-false))
                   (json-error (agent-shell-windows-http--error nil -32700 "Invalid JSON")))))
            (agent-shell-windows-http--send request (if reply 200 202) reply)))))
    ((error quit)
     (agent-shell-windows-http--send
      request 500 (agent-shell-windows-http--error nil -32603 (error-message-string err))))))

(defun agent-shell-windows-http--reject (process status message)
  "Reject one HTTP request on PROCESS with STATUS and MESSAGE."
  (catch 'close-connection
    (agent-shell-windows-http--send
     (make-instance 'ws-request :process process) status (list (cons 'error message))))
  (delete-process process))

(defun agent-shell-windows-http--receive (process chunk)
  "Accumulate a complete request from CHUNK on PROCESS before dispatch.
web-server 0.1.2 may dispatch before the body has arrived."
  (let* ((pending (concat (process-get process 'agent-shell-windows-pending) chunk))
         (boundary (string-match "\r\n\r\n" pending)))
    (cond
     ((and (not boundary) (> (string-bytes pending) 16384))
      (agent-shell-windows-http--reject process 413 "Request headers exceed 16384 bytes"))
     ((not boundary) (process-put process 'agent-shell-windows-pending pending))
     ((> boundary 16384)
      (agent-shell-windows-http--reject process 413 "Request headers exceed 16384 bytes"))
     (t
      (let* ((headers (substring pending 0 (+ boundary 2)))
             (case-fold-search t) (index 0) lengths)
        (while (string-match "^Content-Length:[ \t]*\\([0-9]+\\)[ \t]*\r?$" headers index)
          (push (string-to-number (match-string 1 headers)) lengths)
          (setq index (match-end 0)))
        (cond
         ((string-match-p "^Transfer-Encoding:" headers)
          (agent-shell-windows-http--reject process 501 "Send JSON with Content-Length"))
         ((> (length lengths) 1)
          (agent-shell-windows-http--reject process 400 "Use one Content-Length header"))
         ((and (null lengths) (string-prefix-p "POST " headers))
          (agent-shell-windows-http--reject process 411 "POST requires Content-Length"))
         ((> (or (car lengths) 0) 1000000)
          (agent-shell-windows-http--reject process 413 "Request exceeds 1000000 bytes"))
         (t
          (let ((total (+ boundary 4 (or (car lengths) 0))))
            (if (< (string-bytes pending) total)
                (process-put process 'agent-shell-windows-pending pending)
              (process-put process 'agent-shell-windows-pending nil)
              (ws-filter process (substring pending 0 total)))))))))))

(defun agent-shell-windows-http--filter (process chunk)
  "Handle CHUNK on PROCESS while keeping the shared listener running."
  (condition-case err
      (agent-shell-windows-http--receive process chunk)
    ((error quit)
     (ignore-errors
       (agent-shell-windows-http--reject process 500 (error-message-string err))))))

(defun agent-shell-windows-http--ensure ()
  "Start or reuse the shared HTTP MCP listener."
  (unless (and agent-shell-windows-http--server
               (process-live-p (ws-process agent-shell-windows-http--server)))
    (setq agent-shell-windows-http--server
          (ws-start #'agent-shell-windows-http--handle
                    agent-shell-windows-http-port nil :host agent-shell-windows-http-host))
    (set-process-filter (ws-process agent-shell-windows-http--server)
                        #'agent-shell-windows-http--filter))
  agent-shell-windows-http--server)

(provide 'agent-shell-windows-http)
;;; agent-shell-windows-http.el ends here
