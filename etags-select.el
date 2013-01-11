;;; etags-select.el --- Select from multiple tags

;; Copyright (C) 2007  Scott Frazer

;; Author: Scott Frazer <frazer.scott@gmail.com>
;; Maintainer: Scott Frazer <frazer.scott@gmail.com>
;; Created: 07 Jun 2007
;; Version: 1.13
;; Keywords: etags tags tag select

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; Open a buffer with file/lines of exact-match tags shown.  Select one by
;; going to a line and pressing return.
;;
;; If there is only one match, you can skip opening the selection window by
;; setting a custom variable.  This means you could substitute the key binding
;; for find-tag-at-point with etags-select-find-tag-at-point, although it
;; won't play well with tags-loop-continue.  On the other hand, if you like
;; the behavior of tags-loop-continue you probably don't need this code.
;;
;; I use this:
;; (global-set-key "\M-?" 'etags-select-find-tag-at-point)
;; (global-set-key "\M-." 'etags-select-find-tag)
;; (global-set-key "\M-*" 'etags-select-pop-tag-mark)
;;
;; Contributers of ideas and/or code:
;; David Engster
;; James Ferguson
;;
;;; Change log:
;;
;; 28 Oct 2008 -- v1.13
;;                Add short tag name completion option
;;                Add go-if-tagnum-is-unambiguous option
;; 13 May 2008 -- v1.12
;;                Fix completion bug for XEmacs etags
;;                Add highlighting of tag after jump
;; 28 Apr 2008 -- v1.11
;;                Add tag completion
;; 25 Sep 2007 -- v1.10
;;                Fix save window layout bug
;; 25 Sep 2007 -- v1.9
;;                Add function to prompt for tag to find (instead of using
;;                what is at point)
;; 25 Sep 2007 -- v1.8
;;                Don't mess up user's window layout.
;;                Add function/binding to go to the tag in other window.
;; 10 Sep 2007 -- v1.7
;;                Disambiguate tags with matching suffixes
;; 04 Sep 2007 -- v1.6
;;                Speed up tag searching
;; 27 Jul 2007 -- v1.5
;;                Respect case-fold-search and tags-case-fold-search
;; 24 Jul 2007 -- v1.4
;;                Fix filenames for tag files with absolute paths
;; 24 Jul 2007 -- v1.3
;;                Handle qualified and implicit tags.
;;                Add tag name to display.
;;                Add tag numbers so you can jump directly to one.
;; 13 Jun 2007 -- v1.2
;;                Need to regexp-quote the searched-for string.

;;; Code:

(require 'custom)
(require 'etags)

(eval-when-compile (require 'cl))

;;; Custom stuff

;;;###autoload
(defgroup etags-select-mode nil
  "*etags select mode."
  :group 'etags)

;;;###autoload
(defcustom etags-select-no-select-for-one-match t
  "*If non-nil, don't open the selection window if there is only one
matching tag."
  :group 'etags-select-mode
  :type 'boolean)

;;;###autoload
(defcustom etags-select-mode-hook nil
  "*List of functions to call on entry to etags-select-mode mode."
  :group 'etags-select-mode
  :type 'hook)

;;;###autoload
(defcustom etags-select-highlight-tag-after-jump t
  "*If non-nil, temporarily highlight the tag after you jump to it."
  :group 'etags-select-mode
  :type 'boolean)

;;;###autoload
(defcustom etags-select-highlight-delay 1.0
  "*How long to highlight the tag."
  :group 'etags-select-mode
  :type 'number)

;;;###autoload
(defface etags-select-highlight-tag-face
  '((t (:foreground "white" :background "cadetblue4" :bold t)))
  "Font Lock mode face used to highlight tags."
  :group 'etags-select-mode)

;;;###autoload
(defcustom etags-select-use-short-name-completion nil
  "*Use short tag names during completion.  For example, say you
have a function named foobar in several classes and you invoke
`etags-select-find-tag'.  If this variable is nil, you would have
to type ClassA::foo<TAB> to start completion.  Since avoiding
knowing which class a function is in is the basic idea of this
package, if you set this to t you can just type foo<TAB>.

Only works with GNU Emacs."
  :group 'etags-select-mode
  :type 'boolean)

;;;###autoload
(defcustom etags-select-go-if-unambiguous nil
  "*If non-nil, jump by tag number if it is unambiguous."
  :group 'etags-select-mode
  :type 'boolean)

;;;###autoload
(defcustom etags-select-kill-artifact-buffers t
  "*If non-nil, kill buffers that were opened while building tag selection
buffer."
  :group 'etags-select-mode
  :type 'boolean)

 ;;; Variables

(defvar etags-select-mode-font-lock-keywords nil
  "etags-select font-lock-keywords.")

(defvar etags-select-kill-me-on-pop nil
  "indicates that buffer must be killed when etags-select-pop-tag-mark is called")
(make-variable-buffer-local 'etags-select-kill-me-on-pop)

(defconst etags-select-non-tag-regexp "\\(\\s-*$\\|In:\\|Finding tag:\\)"
  "etags-select non-tag regex.")

(defvar etags-select-match-positions nil)
(make-variable-buffer-local 'etags-select-match-positions)
(put 'etags-select-match-positions 'permanent-local t)


;;; Functions

(if (string-match "XEmacs" emacs-version)
    (fset 'etags-select-match-string 'match-string)
  (fset 'etags-select-match-string 'match-string-no-properties))

;; I use Emacs, but with a hacked version of XEmacs' etags.el, thus this variable

(defvar etags-select-use-xemacs-etags-p (fboundp 'get-tag-table-buffer)
  "Use XEmacs etags?")

(defun etags-select-case-fold-search ()
  "Get case-fold search."
  (when (boundp 'tags-case-fold-search)
    (if (memq tags-case-fold-search '(nil t))
        tags-case-fold-search
      case-fold-search)))

(defun etags-select-buffers-set ()
  "Return a set containing all the buffer that currently exist."
  (let ((buffers-set (make-hash-table :test 'eq)))
    (dolist (buffer (buffer-list))
      (puthash buffer t buffers-set))
    buffers-set))

(defun etags-select-copy-line ()
  "Copy current line."
  (let ((begin (line-beginning-position))
        (end (line-end-position)))
    (buffer-substring-no-properties begin end)))

(defun etags-select-find-next-match (tagname find-tag-fn)
  "Find next tag match. Return nil on failure"
  (condition-case ex
      (funcall find-tag-fn tagname t)
    ('error
     ;; Since we treat all the errors as "no more matches", we need to give at
     ;; least some way for user to understand what went wrong if other error
     ;; happens.
     (message (error-message-string ex))
     nil)))

(defun etags-select-find-matches (tagname find-tag-fn)
  "Find all the matches for a specified tag."
  (save-excursion
    (etags-select-save-tag-marks
      (let* ((buffers-set (etags-select-buffers-set))
             (matches '())
             (file-matches '())
             (last-match-buffer nil)
             (next-p nil)
             ;; If some error happens here it will go through since we want
             ;; user to be aware of it. As the first call to FIND-TAG-FN
             ;; suceeds, we expect successive ones not to fail. With an
             ;; important exception of the last tag in the loop. So basically
             ;; *any* error thrown by the subsequent calls to FIND-TAG-FN is
             ;; treated just as a signal that there're no more matching tags.
             (current-match-buffer (funcall find-tag-fn tagname)))
        (while current-match-buffer
          (setq next-p t)

          (with-current-buffer current-match-buffer
            (let* ((match-point (point))
                   (match-string (etags-select-copy-line))
                   (match (cons match-string match-point)))

              ;; restore old mark
              (if (mark t)
                  (pop-to-mark-command))

              (setq last-match-buffer current-match-buffer)
              (setq file-matches (cons match file-matches))

              (setq current-match-buffer
                    (etags-select-find-next-match tagname find-tag-fn))

              (when (and last-match-buffer
                         (not (eq last-match-buffer current-match-buffer)))
                (let ((match-file (buffer-file-name last-match-buffer)))
                  (setq matches (cons (cons match-file (reverse file-matches))
                                      matches))
                  (setq file-matches '()))

                ;; kill the buffer if it was open by 'find-tag-fn
                (when (and etags-select-kill-artifact-buffers
                           (not (gethash last-match-buffer buffers-set)))
                  (let ((kill-buffer-query-functions '()))
                    (kill-buffer last-match-buffer)))))))
        (reverse matches)))))

(defun etags-select-insert-matches (tagname select-buffer-name matches)
  "Insert matches to tagname in tag-file."
  (set-buffer select-buffer-name)
  (setq etags-select-match-positions (make-hash-table :test 'eq))
  (insert "Finding tag: " tagname "\n")
  (let ((count 0))
    (dolist (match matches count)
      (let ((match-file-name (car match))
            (file-matches (cdr match)))
        (insert "\nIn: " match-file-name "\n")
        (dolist (item file-matches)
          (setq count (1+ count))
          (let ((match-string (car item))
                (match-point (cdr item)))
            (puthash (line-number-at-pos)
                     (cons match-file-name match-point)
                     etags-select-match-positions)
            (insert (int-to-string count) " " match-string "\n")))))))

(defun etags-select-get-tag-table-buffer (tag-file)
  "Get tag table buffer for a tag file."
  (if etags-select-use-xemacs-etags-p
      (get-tag-table-buffer tag-file)
    (visit-tags-table-buffer tag-file)
    (get-file-buffer tag-file)))

;;;###autoload
(defun etags-select-find-tag-at-point (other-window)
  "Do a find-tag-at-point, and display all exact matches.  If only one match is
found, see the `etags-select-no-select-for-one-match' variable to decide what
to do. With C-u prefix tag selection window or the match will be open in
other window."
  (interactive "P")
  (etags-select-find (find-tag-default)
                     'find-tag-noselect other-window))

;;;###autoload
(defun etags-select-find-tag (other-window)
  "Do a find-tag, and display all exact matches.  If only one match is
found, see the `etags-select-no-select-for-one-match' variable to decide what
to do. With C-u prefix tag selection window or the match will be open in
other window."
  (interactive "P")
  (let* ((default (find-tag-default))
         (tagname (completing-read
                   (format "Find tag (default %s): " default)
                   (lambda (string predicate what)
                     (etags-select-complete-tag string predicate what (buffer-name)))
                   nil nil nil 'find-tag-history default)))
    (etags-select-find tagname 'find-tag-noselect other-window)))

;;;###autoload
(defun etags-select-pop-tag-mark ()
  "Like `pop-tag-mark' but also performs some etags-select specific
house keeping."
  (interactive)
  (let ((old-buffer (current-buffer))
        (kill-old-buffer etags-select-kill-me-on-pop))
    (pop-tag-mark)
    (when kill-old-buffer
      (kill-buffer old-buffer))))


(defun etags-select-complete-tag (string predicate what buffer)
  "Tag completion."
  (etags-select-build-completion-table buffer)
  (if (eq what t)
      (all-completions string (etags-select-get-completion-table) predicate)
    (try-completion string (etags-select-get-completion-table) predicate)))

(defun etags-select-build-completion-table (buffer)
  "Build tag completion table."
  (save-excursion
    (set-buffer buffer)
    (let ((tag-files (etags-select-get-tag-files)))
      (mapcar (lambda (tag-file) (etags-select-get-tag-table-buffer tag-file)) tag-files))))

(defun etags-select-get-tag-files ()
  "Get tag files."
  (if etags-select-use-xemacs-etags-p
      (buffer-tag-table-list)
    (mapcar 'tags-expand-table-name tags-table-list)))

(defun etags-select-get-completion-table ()
  "Get the tag completion table."
  (if etags-select-use-xemacs-etags-p
      tag-completion-table
    (tags-completion-table)))

(defun etags-select-tags-completion-table-function ()
  "Short tag name completion."
  (let ((table (make-vector 16383 0))
        (tag-regex "^.*?\\(\^?\\(.+\\)\^A\\|\\<\\(.+\\)[ \f\t()=,;]*\^?[0-9,]\\)")
        (progress-reporter
         (make-progress-reporter
          (format "Making tags completion table for %s..." buffer-file-name)
          (point-min) (point-max))))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (looking-at tag-regex)
          (intern (replace-regexp-in-string ".*[:.']" "" (or (match-string 2) (match-string 3))) table))
        (forward-line 1)
        (progress-reporter-update progress-reporter (point))))
    table))

(unless etags-select-use-xemacs-etags-p
  (defadvice etags-recognize-tags-table (after etags-select-short-name-completion activate)
    "Turn on short tag name completion (maybe)"
    (when etags-select-use-short-name-completion
      (setq tags-completion-table-function 'etags-select-tags-completion-table-function))))

(defun etags-select-find (tagname find-tag-fn other-window)
  "Core tag finding function."
  (when tagname
    (let ((tag-count 0)
          (select-buffer-name (etags-select-make-buffer-name tagname))
          (matches (etags-select-find-matches tagname find-tag-fn)))

      (cond ((null matches)
             ;; This is not very elegant because functions like
             ;; `find-tag-noselect' throw an error when there're no
             ;; matches. And thus we'll never reach this case. But I'll leave
             ;; it here in order to support tag matching functions that behave
             ;; differently.
             (message (concat "No matches for tag \"" tagname "\""))
             (ding))
            (t
             (etags-select-push-tag-mark)
             (get-buffer-create select-buffer-name)
             (set-buffer select-buffer-name)
             (erase-buffer)
             (setq tag-count
                   (etags-select-insert-matches tagname
                                                select-buffer-name matches))

             (cond ((and (= tag-count 1)
                         etags-select-no-select-for-one-match)
                    (set-buffer select-buffer-name)
                    (goto-char (point-min))

                    ;; since selection buffer does not get killed nowadays we
                    ;; need it to look attractive for the user
                    (setq buffer-read-only t)
                    (etags-select-mode tagname)

                    (etags-select-next-tag)
                    (etags-select-do-goto-tag other-window)
                    (kill-buffer select-buffer-name))
                   (t
                    (set-buffer select-buffer-name)
                    (goto-char (point-min))
                    (etags-select-next-tag)
                    (set-buffer-modified-p nil)
                    (setq buffer-read-only t)
                    (if other-window
                        (switch-to-buffer-other-window select-buffer-name)
                      (switch-to-buffer select-buffer-name))
                    (etags-select-mode tagname))))))))

(defun etags-select-do-goto-tag (&optional other-window)
  "Goto the file/line of the tag under the cursor. Do not push tag mark."
  ;; TODO remove me
  (interactive)
  (let* ((line (line-number-at-pos))
         (match-position (gethash line etags-select-match-positions))
         (match-file (car match-position))
         (match-point (cdr match-position)))
    (if (not match-position)
        (message "Please put the cursor on a line with the tag.")
      (if other-window
          (find-file-other-window match-file)
        (find-file match-file))
      (goto-char match-point))))

(defun etags-select-highlight (beg end)
  "Highlight a region temporarily."
  (if (featurep 'xemacs)
      (let ((extent (make-extent beg end)))
        (set-extent-property extent 'face 'etags-select-highlight-tag-face)
        (sit-for etags-select-highlight-delay)
        (delete-extent extent))
    (let ((ov (make-overlay beg end)))
      (overlay-put ov 'face 'etags-select-highlight-tag-face)
      (sit-for etags-select-highlight-delay)
      (delete-overlay ov))))

(defun etags-select-goto-tag (other-window)
  "Goto the file/line of the tag under the cursor. Push tag mark."
  (interactive "P")
  (etags-select-push-tag-mark)
  (etags-select-do-goto-tag other-window))

(defun etags-select-goto-tag-other-window ()
  "Goto the file/line of the tag under the cursor in other window.
Push tag mark."
  (interactive)
  (etags-select-goto-tag t))

(defun etags-select-next-tag ()
  "Move to next tag in buffer."
  (interactive)
  (beginning-of-line)
  (when (not (eobp))
    (forward-line))
  (while (and (looking-at etags-select-non-tag-regexp) (not (eobp)))
    (forward-line))
  (when (eobp)
    (ding)))

(defun etags-select-previous-tag ()
  "Move to previous tag in buffer."
  (interactive)
  (beginning-of-line)
  (when (not (bobp))
    (forward-line -1))
  (while (and (looking-at etags-select-non-tag-regexp) (not (bobp)))
    (forward-line -1))
  (when (bobp)
    (ding)))

(defun etags-select-quit ()
  "Quit etags-select buffer."
  (interactive)
  (kill-buffer nil))

(defun etags-select-by-tag-number (first-digit other-window)
  "Select a tag by number."
  (let ((current-point (point)) tag-num)
    (if (and etags-select-go-if-unambiguous (not (re-search-forward (concat "^" first-digit) nil t 2)))
        (setq tag-num first-digit)
      (setq tag-num (read-from-minibuffer "Tag number? " first-digit)))
    (goto-char (point-min))
    (if (re-search-forward (concat "^" tag-num) nil t)
        (etags-select-goto-tag other-window)
      (goto-char current-point)
      (message (concat "Couldn't find tag number " tag-num))
      (ding))))

(defun etags-select-push-tag-mark ()
  "Push tag mark into the ring."
  (if etags-select-use-xemacs-etags-p
      (push-tag-mark)
    (ring-insert find-tag-marker-ring (point-marker))))

(defun etags-select-get-tag-marks ()
  "Return current state of tag marks."
  (if etags-select-use-xemacs-etags-p
      (cons (copy-tree tag-mark-stack1) (copy-tree tag-mark-stack2))
    (ring-copy find-tag-marker-ring)))

(defun etags-select-set-tag-marks (marks)
  "Set current tag marks to the value previously returned by
`etags-select-get-tag-marks'."
  (if etags-select-use-xemacs-etags-p
      (progn (setq tag-mark-stack1 (car marks))
             (setq tag-mark-stack2 (cdr marks)))
    (setq find-tag-marker-ring marks)))

(defmacro etags-select-save-tag-marks (&rest body)
  "Execute body that potentially pushes or pops tag marks. Restore the old value
after that."
  (declare (indent 0)
           (debug (&rest form)))
  (let ((var (make-symbol "old-marks")))
    `(let ((,var (etags-select-get-tag-marks)))
       (unwind-protect
           (progn ,@body)
         (etags-select-set-tag-marks ,var)))))

(defun etags-select-make-buffer-name (tagname)
  "Make unique name for tag selection buffer."
  (let ((i 0)
        break
        candidate-name)
    (while (not break)
      (setq candidate-name (format "*etags-select (%s) (%d)*" tagname i))
      (unless (get-buffer candidate-name)
        ;; free name
        (setq break t))
      (setq i (1+ i)))
    candidate-name))

;;; Keymap

(defvar etags-select-mode-map nil "'etags-select-mode' keymap.")
(if (not etags-select-mode-map)
    (let ((map (make-keymap)))
      (define-key map [(return)] 'etags-select-goto-tag)
      (define-key map [(meta return)] 'etags-select-goto-tag-other-window)
      (define-key map [(down)] 'etags-select-next-tag)
      (define-key map [(up)] 'etags-select-previous-tag)
      (define-key map "n" 'etags-select-next-tag)
      (define-key map "p" 'etags-select-previous-tag)
      (define-key map "q" 'etags-select-quit)
      (define-key map "0" (lambda (other-window)
                            (interactive "P")
                            (etags-select-by-tag-number "0" other-window)))
      (define-key map "1" (lambda (other-window)
                            (interactive "P")
                            (etags-select-by-tag-number "1" other-window)))
      (define-key map "2" (lambda (other-window)
                            (interactive "P")
                            (etags-select-by-tag-number "2" other-window)))
      (define-key map "3" (lambda (other-window)
                            (interactive "P")
                            (etags-select-by-tag-number "3" other-window)))
      (define-key map "4" (lambda (other-window)
                            (interactive "P")
                            (etags-select-by-tag-number "4" other-window)))
      (define-key map "5" (lambda (other-window)
                            (interactive "P")
                            (etags-select-by-tag-number "5" other-window)))
      (define-key map "6" (lambda (other-window)
                            (interactive "P")
                            (etags-select-by-tag-number "6" other-window)))
      (define-key map "7" (lambda (other-window)
                            (interactive "P")
                            (etags-select-by-tag-number "7" other-window)))
      (define-key map "8" (lambda (other-window)
                            (interactive "P")
                            (etags-select-by-tag-number "8" other-window)))
      (define-key map "9" (lambda (other-window)
                            (interactive "P")
                            (etags-select-by-tag-number "9" other-window)))
      (setq etags-select-mode-map map)))

;;; Mode startup

(defun etags-select-mode (tagname)
  "etags-select-mode is a mode for browsing through tags.\n\n
\\{etags-select-mode-map}"
  (interactive)
  (kill-all-local-variables)
  (setq etags-select-kill-me-on-pop t)
  (setq major-mode 'etags-select-mode)
  (setq mode-name "etags-select")
  (set-syntax-table text-mode-syntax-table)
  (use-local-map etags-select-mode-map)
  (make-local-variable 'font-lock-defaults)
  (setq etags-select-mode-font-lock-keywords
        (list (list "^\\(Finding tag:\\)" '(1 font-lock-keyword-face))
              (list "^\\(In:\\) \\(.*\\)" '(1 font-lock-keyword-face) '(2 font-lock-string-face))
              (list "^[0-9]+ \\[\\(.+?\\)\\]" '(1 font-lock-type-face))
              (list tagname '(0 font-lock-function-name-face))))
  (setq font-lock-defaults '(etags-select-mode-font-lock-keywords))
  (setq overlay-arrow-position nil)
  (run-hooks 'etags-select-mode-hook))

(provide 'etags-select)
;;; etags-select.el ends here
