;;; locate-dired.el --- Locate in Dired Mode

;; Copyright (C) 2019 Julien Masson.

;; Author: Julien Masson
;; URL: https://github.com/JulienMasson/locate-dired
;; Created: 2019-06-06

;;; License

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Code:

(require 'dired)
(require 'subr-x)
(require 'tramp)

;;; External vars

(defcustom locate-dired-switches "-dilsb"
  "Switches arguments used when performing ls on files found")

(defcustom locate-dired-prunepaths (list ".bzr" ".hg" ".git" ".svn" ".repo")
  "List of directories to not put in the locate database")

;;; Internal vars

(defconst locate-dired--updatedb "updatedb.findutils"
  "Executable to update/create a locate database")

(defconst locate-dired--locate "locate.findutils"
  "Executable to list files in databases that match a pattern")

(defconst locate-dired--database "locate.db"
  "Locate database file name")

(defconst locate-dired--search-header "  ━▶ Locate search: "
  "Message inserted when searching pattern")

(defconst locate-dired--create-header "  ━▶ Creating locate database ..."
  "Message inserted when creating locate database")

(defvar locate-dired--search--history nil)

;;; Internal Functions

(defun locate-dired--prompt-pattern ()
  "Prompt pattern used when searching in locate database."
  (let ((pattern (read-string "Locate search: " nil
			      'locate-dired--search--history)))
    (if (string= pattern "")
	(locate-dired--prompt-pattern)
      pattern)))

(defun locate-dired--untramp-path (path)
  "Return localname of PATH."
  (if (tramp-tramp-file-p path)
      (tramp-file-name-localname (tramp-dissect-file-name path))
    path))

(defun locate-dired--insert (buffer str)
  "Insert SRT in locate dired BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (let ((inhibit-read-only t))
	(goto-char (point-max))
	(insert str)))))

(defun locate-dired--switch-to-buffer (buffer)
  "Custom `switch-to-buffer' command."
  (if (get-buffer-window-list buffer)
      (pop-to-buffer buffer)
    (switch-to-buffer-other-window buffer)))

(defun locate-dired--find-program (program-name)
  "Find PROGRAM-NAME executable in `default-directory'."
  (if (tramp-tramp-file-p default-directory)
      (with-parsed-tramp-file-name default-directory nil
	(let ((buffer (tramp-get-connection-buffer v))
	      (cmd (concat "which " program-name)))
	  (with-current-buffer buffer
	    (tramp-send-command v cmd)
	    (goto-char (point-min))
	    (when (looking-at "^\\(.+\\)")
	      (match-string 1)))))
    (executable-find program-name)))

(defun locate-dired--find-buffer (database pattern)
  "Find lcoate dired buffer based on DATABASE and PATTERN."
  (seq-find (lambda (buffer)
	      (with-current-buffer buffer
		(let ((dtb (get-text-property (point-min) 'locate-database))
		      (pat (get-text-property (point-min) 'locate-pattern)))
		  (and (string= major-mode "dired-mode")
		       (string= database dtb)
		       (string= pattern pat)))))
	    (buffer-list)))

(defun locate-dired--buffer-name (database pattern)
  "Return locate buffer name."
  (if-let ((buffer (locate-dired--find-buffer database pattern)))
      (buffer-name buffer)
    (generate-new-buffer-name (format "*locate: %s*" pattern))))

(defun locate-dired--create-buffer (database pattern)
  "Create a locate dired buffer."
  (let ((plist `(locate-database ,database locate-pattern ,pattern))
	(buffer-name (locate-dired--buffer-name database pattern))
	(inhibit-read-only t))
    (with-current-buffer (get-buffer-create buffer-name)
      (erase-buffer)
      (insert (format "  %s:\n\n" (file-name-directory database)))
      (add-text-properties (point-min) (point-max) plist)
      (dired-mode default-directory locate-dired-switches)
      (set (make-local-variable 'dired-subdir-alist)
	   (list (cons default-directory (point-min-marker))))
      (set (make-local-variable 'revert-buffer-function)
	   `(lambda (ignore-auto noconfirm)
	      (locate-dired--create-search ,database ,pattern)))
      (locate-dired--switch-to-buffer (current-buffer)))))

(defun locate-dired--locate-args (locate database pattern)
  "Return string of locate command."
  (let* ((dir (file-name-directory database))
	 (locate-cmd (format "%s --basename --database=%s %s"
			     locate database pattern))
	 (xargs-cmd (concat "xargs -r ls " locate-dired-switches))
	 (sed-cmd (format "sed 's,^\\(.*\\)%s\\(.*\\),  \\1\\2,g'" dir)))
  (mapconcat 'identity (list locate-cmd xargs-cmd sed-cmd) " | ")))

(defun locate-dired--updatedb-args (database)
  "Return list of updatedb arguments."
  (let* ((dir (file-name-directory database))
	 (prunepaths (if locate-dired-prunepaths
			 (mapconcat (lambda (elem)
				      (concat dir elem))
				    locate-dired-prunepaths " "))))
    (list (concat "--localpaths=" dir)
	  (if prunepaths
	      (format "--prunepaths=\"%s\"" prunepaths))
	  (concat "--output=" database))))

(defun locate-dired--move-to-search (buffer)
  "Move point to search results in BUFFER."
  (with-current-buffer buffer
    (goto-char (point-min))
    (search-forward locate-dired--search-header nil t)
    (forward-line)
    (skip-chars-forward " \t\n")))

(defun locate-dired--process-sentinel (process status)
  "Process results when the search has finished."
  (when (eq (process-exit-status process) 0)
    (let ((buffer (process-buffer process)))
      (when (with-current-buffer buffer (equal (point) (point-max)))
	(locate-dired--insert buffer "  --- No files found ---\n"))
      (locate-dired--insert buffer (concat "\n  Locate finished at "
					   (current-time-string))))))

(defun locate-dired--process-filter (process str)
  "Insert result in the PROCESS buffer."
  (locate-dired--insert (process-buffer process) str))

(defun locate-dired--search (database pattern)
  "Search PATTERN in DATABASE."
  (let ((buffer (locate-dired--create-buffer database pattern)))
    (if-let ((locate (locate-dired--find-program locate-dired--locate)))
	(let* ((local-database (locate-dired--untramp-path
				(expand-file-name database)))
	       (args (locate-dired--locate-args locate local-database pattern))
	       (process (start-file-process "bash" buffer "bash" "-c" args)))
	  (locate-dired--insert buffer (concat locate-dired--search-header
					       pattern "\n\n"))
	  (set-process-filter process 'locate-dired--process-filter)
	  (set-process-sentinel process 'locate-dired--process-sentinel)
	  (locate-dired--move-to-search buffer))
      (locate-dired--insert buffer (concat locate-dired--locate " not found !")))))

(defun locate-dired--process-create-sentinel (process status)
  "Search pattern if the database has been successfully created."
  (when (eq (process-exit-status process) 0)
    (with-current-buffer (process-buffer process)
      (let ((database (get-text-property (point-min) 'locate-database))
	    (pattern (get-text-property (point-min) 'locate-pattern))
	    (inhibit-read-only t))
	(goto-char (point-min))
	(search-forward locate-dired--create-header nil t)
	(delete-region (point) (point-max))
	(locate-dired--search database pattern)))))

(defun locate-dired--create-search (database pattern)
  "Create locate DATABASE and search PATTERN."
  (let ((buffer (locate-dired--create-buffer database pattern)))
    (if-let ((updatedb (locate-dired--find-program locate-dired--updatedb)))
	(let* ((local-database (locate-dired--untramp-path
				(expand-file-name database)))
	       (args (locate-dired--updatedb-args local-database))
	       (process (apply 'start-file-process "updatedb" buffer
			       updatedb args)))
	  (locate-dired--insert buffer locate-dired--create-header)
	  (set-process-sentinel process 'locate-dired--process-create-sentinel))
      (locate-dired--insert buffer (concat locate-dired--updatedb " not found !")))))

;;; External Functions

(defun locate-dired (pattern)
  "Search PATTERN from current `default-directory'.
If no database is found, we ask to create one and process the request."
  (interactive (list (locate-dired--prompt-pattern)))
  (let* ((database (concat default-directory locate-dired--database))
	 (prompt (format "Create locate database (%s): "
			 (propertize database 'face 'success))))
    (if (file-exists-p database)
	(locate-dired--search database pattern)
      (when (yes-or-no-p prompt)
	(locate-dired--create-search database pattern)))))

(provide 'locate-dired)
