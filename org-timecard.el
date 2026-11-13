;;; org-timecard.el --- Timecard reports from Org clock data -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Michael L. Gran

;; Version: 0.1
;; Package-Requires: ((emacs "27.1") (org "9.4"))
;; Keywords: outlines, calendar
;; URL: https://github.com/spk121/org-timecard

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A week of work is recorded in an Org file.  Each task is a headline
;; carrying two tags, in this order: the charge number, then the labor
;; type.  An optional third tag gives the priority: high, medium or
;; low.  A task without one is medium.  Time is recorded with the usual
;; Org clock commands.
;;
;;     **** Laser Assemblies                                :B101:design:
;;     :LOGBOOK:
;;     CLOCK: [2026-11-12 Thu 09:25]--[2026-11-12 Thu 19:25] => 10:00
;;     :END:
;;
;; Four reports are built from the clock lines:
;;
;;   M-x org-timecard-log-report       time ranges in chronological order
;;   M-x org-timecard-charge-report    hours per day per charge number
;;   M-x org-timecard-labor-report     hours per day per labor type
;;   M-x org-timecard-priority-report  share of each day per priority
;;   M-x org-timecard-report           all four
;;
;; The same tables can be kept inside the Org file as dynamic blocks,
;; refreshed with C-c C-c on the #+BEGIN line:
;;
;;     #+BEGIN: timecard :report charge
;;     #+END:
;;
;; where :report is one of log, charge, labor or priority.
;;
;; The log report also warns about time ranges that overlap, and notes
;; gaps between ranges shorter than `org-timecard-gap-minutes'.
;;
;; The reports cover the accessible part of the buffer, so narrowing to
;; a subtree restricts them to that subtree.
;;
;; M-x org-timecard-reminder-mode flashes the screen as a reminder to
;; update the timecard each time Emacs has been idle, with no keyboard
;; or mouse input, for another `org-timecard-reminder-minutes'.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'org-table)

(defgroup org-timecard nil
  "Timecard reports from Org clock data."
  :group 'org)

(defcustom org-timecard-hours-format "%.2f"
  "Format string used to print a number of hours."
  :type 'string)

(defcustom org-timecard-missing "(none)"
  "Text shown for a task that has no charge number or no labor type."
  :type 'string)

(defconst org-timecard-gap-minutes 240
  "Longest gap, in minutes, that the log report points out.
A gap between one time range and the next that is shorter than this is
noted in the report.  Longer gaps are taken to be time off between
shifts and are not mentioned.")

(defconst org-timecard-priorities '("high" "medium" "low")
  "The priorities a task can have, in the order the report lists them.")

(defconst org-timecard-default-priority "medium"
  "Priority of a task that has no priority tag.")

(defcustom org-timecard-percent-format "%.0f%%"
  "Format string used to print a percentage."
  :type 'string)

(defconst org-timecard-reminder-minutes 60
  "Minutes of idle time between flashes of `org-timecard-reminder-mode'.
Idle time is the time since the last keyboard or mouse input.  The
screen flashes each time another this many minutes of it have passed.")

(defconst org-timecard-reminder-flashes 2
  "Number of times the screen flashes for a timecard reminder.")

(defconst org-timecard-reminder-flash-seconds 0.15
  "Seconds each half of a reminder flash lasts.")

(defcustom org-timecard-buffer-name "*Org Timecard*"
  "Name of the buffer in which the report commands show their tables."
  :type 'string)

;;;; Collecting clock entries

(defun org-timecard--entries ()
  "Return the closed clock entries of the current buffer, oldest first.
Each entry is a plist with keys :start and :end (Lisp time values),
:task, :charge, :labor and :priority (strings).  Running clocks are
ignored."
  (let ((entries
         (org-element-map (org-element-parse-buffer) 'clock
           (lambda (clock)
             (let ((ts (org-element-property :value clock))
                   (hl (org-element-lineage clock '(headline))))
               (when (and hl (eq (org-element-property :status clock) 'closed))
                 (let ((tags (mapcar #'substring-no-properties
                                     (org-element-property :tags hl))))
                   (list :start (org-timestamp-to-time ts)
                         :end (org-timestamp-to-time ts t)
                         :task (org-element-property :raw-value hl)
                         :charge (or (nth 0 tags) org-timecard-missing)
                         :labor (or (nth 1 tags) org-timecard-missing)
                         :priority (org-timecard--priority
                                    (nth 2 tags))))))))))
    (sort entries
          (lambda (a b)
            (time-less-p (plist-get a :start) (plist-get b :start))))))

(defun org-timecard--priority (tag)
  "Return the priority named by TAG, a string or nil.
The result is a member of `org-timecard-priorities'.  It is
`org-timecard-default-priority' when TAG is nil or not a priority."
  (or (and tag (car (member (downcase tag) org-timecard-priorities)))
      org-timecard-default-priority))

(defun org-timecard--day-slices (start end)
  "Split the time range START to END at each midnight.
Return a list of (DAY . SECONDS), where DAY is a string such as
\"2026-11-13 Fri\"."
  (let (slices)
    (while (time-less-p start end)
      (let* ((d (decode-time start))
             (midnight (encode-time (list 0 0 0 (1+ (nth 3 d)) (nth 4 d)
                                          (nth 5 d) nil -1 nil)))
             (stop (if (time-less-p midnight end) midnight end)))
        (push (cons (format-time-string "%Y-%m-%d %a" start)
                    (float-time (time-subtract stop start)))
              slices)
        (setq start stop)))
    (nreverse slices)))

;;;; Building tables

(defun org-timecard--hours (seconds)
  "Format SECONDS as hours, or as an empty string when zero."
  (if (zerop seconds) ""
    (format org-timecard-hours-format (/ seconds 3600.0))))

(defun org-timecard--log-table (entries)
  "Return the time-ordered table for ENTRIES."
  (append
   (list '("Time" "Task" "Charge" "Labor") 'hline)
   (mapcar (lambda (e)
             (list (concat (org-timecard--stamp (plist-get e :start))
                           "--"
                           (org-timecard--stamp (plist-get e :end)))
                   ;; A literal "|" would start a new table column.
                   (replace-regexp-in-string "|" "\\vert{}"
                                             (plist-get e :task) t t)
                   (plist-get e :charge)
                   (plist-get e :labor)))
           entries)))

(defun org-timecard--stamp (time)
  "Format TIME as an inactive Org timestamp."
  (format-time-string "[%Y-%m-%d %a %H:%M]" time))

(defun org-timecard--log-notes (entries)
  "Return a list of remarks about overlaps and short gaps in ENTRIES.
ENTRIES must be sorted by start time.  Each time range is compared with
the latest-ending range before it.  An overlap gives a warning.  A gap
shorter than `org-timecard-gap-minutes' gives a note."
  (let (notes last)
    (dolist (e entries)
      (when last
        (let* ((start (plist-get e :start))
               (end (plist-get e :end))
               (last-end (plist-get last :end))
               (tasks (format "\"%s\" and \"%s\""
                              (plist-get last :task) (plist-get e :task))))
          (cond
           ((time-less-p start last-end)
            (let ((stop (if (time-less-p end last-end) end last-end)))
              (push (format "WARNING: overlap of %s, %s--%s, between %s"
                            (org-timecard--span start stop)
                            (org-timecard--stamp start)
                            (org-timecard--stamp stop)
                            tasks)
                    notes)))
           ((and (time-less-p last-end start)
                 (< (float-time (time-subtract start last-end))
                    (* 60 org-timecard-gap-minutes)))
            (push (format "Note: gap of %s, %s--%s, between %s"
                          (org-timecard--span last-end start)
                          (org-timecard--stamp last-end)
                          (org-timecard--stamp start)
                          tasks)
                  notes)))))
      (when (or (null last)
                (time-less-p (plist-get last :end) (plist-get e :end)))
        (setq last e)))
    (nreverse notes)))

(defun org-timecard--span (start end)
  "Format the length of time from START to END as H:MM."
  (let ((minutes (round (float-time (time-subtract end start)) 60)))
    (format "%d:%02d" (/ minutes 60) (% minutes 60))))

(defun org-timecard--pivot-table (entries key)
  "Return a table of hours per day for ENTRIES, with one column per KEY value.
KEY is :charge or :labor."
  (let ((cells (make-hash-table :test #'equal)) ; (day . column) -> seconds
        days columns)
    (dolist (e entries)
      (let ((column (plist-get e key)))
        (cl-pushnew column columns :test #'equal)
        (dolist (slice (org-timecard--day-slices (plist-get e :start)
                                                 (plist-get e :end)))
          (cl-pushnew (car slice) days :test #'equal)
          (cl-incf (gethash (cons (car slice) column) cells 0)
                   (cdr slice)))))
    (setq days (sort days #'string<)
          columns (sort columns #'string<))
    (let ((row (lambda (label days)
                 ;; One row summing the cells of DAYS, with a row total.
                 (let* ((sums (mapcar
                               (lambda (column)
                                 (apply #'+ (mapcar
                                             (lambda (day)
                                               (gethash (cons day column)
                                                        cells 0))
                                             days)))
                               columns)))
                   (append (list label)
                           (mapcar #'org-timecard--hours sums)
                           (list (org-timecard--hours (apply #'+ sums))))))))
      (append
       (list (append '("Day") columns '("Total")) 'hline)
       (mapcar (lambda (day) (funcall row day (list day))) days)
       (list 'hline (funcall row "Total" days))))))

(defun org-timecard--percent (seconds total)
  "Format SECONDS as a percentage of TOTAL, or as an empty string when zero."
  (if (or (zerop seconds) (zerop total)) ""
    (format org-timecard-percent-format (/ (* 100.0 seconds) total))))

(defun org-timecard--priority-table (entries)
  "Return a table of the share of each day ENTRIES spend on each priority.
Each row gives the percentage of that day's clocked time."
  (let ((cells (make-hash-table :test #'equal)) ; (day . priority) -> seconds
        days)
    (dolist (e entries)
      (dolist (slice (org-timecard--day-slices (plist-get e :start)
                                               (plist-get e :end)))
        (cl-pushnew (car slice) days :test #'equal)
        (cl-incf (gethash (cons (car slice) (plist-get e :priority)) cells 0)
                 (cdr slice))))
    (setq days (sort days #'string<))
    (let ((row (lambda (label days)
                 (let* ((sums (mapcar
                               (lambda (priority)
                                 (apply #'+ (mapcar
                                             (lambda (day)
                                               (gethash (cons day priority)
                                                        cells 0))
                                             days)))
                               org-timecard-priorities))
                        (total (apply #'+ sums)))
                   (cons label
                         (mapcar (lambda (sum)
                                   (org-timecard--percent sum total))
                                 sums))))))
      (append
       (list (cons "Day" (mapcar #'capitalize org-timecard-priorities)) 'hline)
       (mapcar (lambda (day) (funcall row day (list day))) days)
       (list 'hline (funcall row "All days" days))))))

(defun org-timecard--render (report)
  "Return the text of REPORT: log, charge, labor or priority, a symbol.
The text is an aligned Org table.  For the log report it is followed by
a list of overlap warnings and gap notes, if there are any."
  (let* ((entries (org-timecard--entries))
         (table (pcase report
                  ('log (org-timecard--log-table entries))
                  ('charge (org-timecard--pivot-table entries :charge))
                  ('labor (org-timecard--pivot-table entries :labor))
                  ('priority (org-timecard--priority-table entries))
                  (_ (user-error "Unknown timecard report: %s" report))))
         (notes (and (eq report 'log) (org-timecard--log-notes entries))))
    (with-temp-buffer
      (insert (orgtbl-to-orgtbl table nil))
      (org-table-align)
      (goto-char (point-max))
      (when notes
        (insert "\n")
        (dolist (note notes)
          (insert "\n- " note)))
      (buffer-string))))

;;;; Commands

(defconst org-timecard--titles
  '((log . "Time log")
    (charge . "Hours by day and charge number")
    (labor . "Hours by day and labor type")
    (priority . "Share of each day by priority")))

(defun org-timecard--show (reports)
  "Show REPORTS, a list of report symbols, for the current buffer."
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (let ((tables (mapcar (lambda (r) (cons r (org-timecard--render r)))
                        reports))
        (source (buffer-name)))
    (with-current-buffer (get-buffer-create org-timecard-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (insert "#+TITLE: Timecard for " source "\n")
        (dolist (tbl tables)
          (insert "\n* " (cdr (assq (car tbl) org-timecard--titles)) "\n\n")
          (insert (cdr tbl) "\n"))
        (goto-char (point-min)))
      (pop-to-buffer (current-buffer)))))

;;;###autoload
(defun org-timecard-log-report ()
  "Show every clocked time range in chronological order.
The columns are the time range, task name, charge number and labor type.
Below the table, warn about time ranges that overlap and note any gap
between ranges that is shorter than `org-timecard-gap-minutes'."
  (interactive)
  (org-timecard--show '(log)))

;;;###autoload
(defun org-timecard-charge-report ()
  "Show the hours worked each day against each charge number."
  (interactive)
  (org-timecard--show '(charge)))

;;;###autoload
(defun org-timecard-labor-report ()
  "Show the hours worked each day in each labor type."
  (interactive)
  (org-timecard--show '(labor)))

;;;###autoload
(defun org-timecard-priority-report ()
  "Show the percentage of each day spent on each priority of task."
  (interactive)
  (org-timecard--show '(priority)))

;;;###autoload
(defun org-timecard-report ()
  "Show all four timecard reports for the current Org buffer."
  (interactive)
  (org-timecard--show '(log charge labor priority)))

;;;; Dynamic block

;;;###autoload
(defun org-dblock-write:timecard (params)
  "Write a timecard table as a dynamic block.
PARAMS is the block's property list; :report selects the table and is
one of log (the default), charge, labor or priority."
  (let ((report (or (plist-get params :report) 'log)))
    (insert (org-timecard--render
             (if (stringp report) (intern report) report)))))

;;;###autoload
(defun org-timecard-insert-dblock (report)
  "Insert a timecard dynamic block for REPORT at point."
  (interactive
   (list (completing-read "Report: " '("log" "charge" "labor" "priority")
                          nil t)))
  (org-create-dblock (list :name "timecard" :report (intern report)))
  (org-update-dblock))

(when (fboundp 'org-dynamic-block-define)
  (org-dynamic-block-define "timecard" #'org-timecard-insert-dblock))

;;;; Reminder

(defvar org-timecard--reminder-timer nil
  "The idle timer of `org-timecard-reminder-mode', or nil.
It gives the first flash of each stretch of idle time.")

(defvar org-timecard--reminder-repeat-timer nil
  "The timer giving the later flashes of a stretch of idle time, or nil.")

(defun org-timecard--reminder-stop-repeat ()
  "Cancel the timer that repeats the reminder, if there is one."
  (when org-timecard--reminder-repeat-timer
    (cancel-timer org-timecard--reminder-repeat-timer)
    (setq org-timecard--reminder-repeat-timer nil)))

(defun org-timecard--reminder-first ()
  "Give the first reminder of a stretch of idle time and schedule the rest."
  (org-timecard--reminder-stop-repeat)
  (let ((seconds (* 60 org-timecard-reminder-minutes)))
    (setq org-timecard--reminder-repeat-timer
          (run-with-timer seconds seconds #'org-timecard--reminder-again)))
  (org-timecard-flash))

(defun org-timecard--reminder-again ()
  "Give a later reminder, or stop repeating if the idle stretch has ended."
  (let ((idle (current-idle-time)))
    (if (and idle (>= (float-time idle) (* 60 org-timecard-reminder-minutes)))
        (org-timecard-flash)
      (org-timecard--reminder-stop-repeat))))

(defun org-timecard-flash ()
  "Flash the screen as a reminder to update the timecard.
The colors of every frame are swapped and restored
`org-timecard-reminder-flashes' times."
  (interactive)
  (dotimes (i (* 2 org-timecard-reminder-flashes))
    (run-with-timer (* i org-timecard-reminder-flash-seconds) nil
                    #'invert-face 'default))
  (message "Remember to update your timecard"))

;;;###autoload
(define-minor-mode org-timecard-reminder-mode
  "Flash the screen when it is time to update the timecard.
The flash comes when Emacs has been idle, with no keyboard or mouse
input, for `org-timecard-reminder-minutes', and again each time that
many more minutes pass, until there is input."
  :global t
  :group 'org-timecard
  (when org-timecard--reminder-timer
    (cancel-timer org-timecard--reminder-timer)
    (setq org-timecard--reminder-timer nil))
  (org-timecard--reminder-stop-repeat)
  (when org-timecard-reminder-mode
    (setq org-timecard--reminder-timer
          (run-with-idle-timer (* 60 org-timecard-reminder-minutes) t
                               #'org-timecard--reminder-first))))

(provide 'org-timecard)

;;; org-timecard.el ends here
