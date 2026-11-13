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
;; carrying exactly two tags, in this order: the charge number, then
;; the labor type.  Time is recorded with the usual Org clock commands.
;;
;;     **** Laser Assemblies                                :B101:design:
;;     :LOGBOOK:
;;     CLOCK: [2026-11-12 Thu 09:25]--[2026-11-12 Thu 19:25] => 10:00
;;     :END:
;;
;; Three reports are built from the clock lines:
;;
;;   M-x org-timecard-log-report     time ranges in chronological order
;;   M-x org-timecard-charge-report  hours per day per charge number
;;   M-x org-timecard-labor-report   hours per day per labor type
;;   M-x org-timecard-report         all three
;;
;; The same tables can be kept inside the Org file as dynamic blocks,
;; refreshed with C-c C-c on the #+BEGIN line:
;;
;;     #+BEGIN: timecard :report charge
;;     #+END:
;;
;; where :report is one of log, charge or labor.
;;
;; The reports cover the accessible part of the buffer, so narrowing to
;; a subtree restricts them to that subtree.

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

(defcustom org-timecard-buffer-name "*Org Timecard*"
  "Name of the buffer in which the report commands show their tables."
  :type 'string)

;;;; Collecting clock entries

(defun org-timecard--entries ()
  "Return the closed clock entries of the current buffer, oldest first.
Each entry is a plist with keys :start and :end (Lisp time values),
:task, :charge and :labor (strings).  Running clocks are ignored."
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
                         :labor (or (nth 1 tags) org-timecard-missing)))))))))
    (sort entries
          (lambda (a b)
            (time-less-p (plist-get a :start) (plist-get b :start))))))

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
             (list (concat
                    (format-time-string "[%Y-%m-%d %a %H:%M]"
                                        (plist-get e :start))
                    "--"
                    (format-time-string "[%Y-%m-%d %a %H:%M]"
                                        (plist-get e :end)))
                   (plist-get e :task)
                   (plist-get e :charge)
                   (plist-get e :labor)))
           entries)))

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

(defun org-timecard--table (report)
  "Return the table for REPORT, one of the symbols log, charge or labor."
  (let ((entries (org-timecard--entries)))
    (pcase report
      ('log (org-timecard--log-table entries))
      ('charge (org-timecard--pivot-table entries :charge))
      ('labor (org-timecard--pivot-table entries :labor))
      (_ (user-error "Unknown timecard report: %s" report)))))

(defun org-timecard--insert-table (table)
  "Insert TABLE at point as an aligned Org table."
  (insert (orgtbl-to-orgtbl table nil))
  (org-table-align))

;;;; Commands

(defconst org-timecard--titles
  '((log . "Time log")
    (charge . "Hours by day and charge number")
    (labor . "Hours by day and labor type")))

(defun org-timecard--show (reports)
  "Show REPORTS, a list of report symbols, for the current buffer."
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (let ((tables (mapcar (lambda (r) (cons r (org-timecard--table r)))
                        reports))
        (source (buffer-name)))
    (with-current-buffer (get-buffer-create org-timecard-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (insert "#+TITLE: Timecard for " source "\n")
        (dolist (tbl tables)
          (insert "\n* " (cdr (assq (car tbl) org-timecard--titles)) "\n\n")
          (org-timecard--insert-table (cdr tbl))
          (goto-char (point-max))
          (insert "\n"))
        (goto-char (point-min)))
      (pop-to-buffer (current-buffer)))))

;;;###autoload
(defun org-timecard-log-report ()
  "Show every clocked time range in chronological order.
The columns are the time range, task name, charge number and labor type."
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
(defun org-timecard-report ()
  "Show all three timecard reports for the current Org buffer."
  (interactive)
  (org-timecard--show '(log charge labor)))

;;;; Dynamic block

;;;###autoload
(defun org-dblock-write:timecard (params)
  "Write a timecard table as a dynamic block.
PARAMS is the block's property list; :report selects the table and is
one of log (the default), charge or labor."
  (let ((report (or (plist-get params :report) 'log)))
    (org-timecard--insert-table
     (org-timecard--table (if (stringp report) (intern report) report)))))

;;;###autoload
(defun org-timecard-insert-dblock (report)
  "Insert a timecard dynamic block for REPORT at point."
  (interactive
   (list (completing-read "Report: " '("log" "charge" "labor") nil t)))
  (org-create-dblock (list :name "timecard" :report (intern report)))
  (org-update-dblock))

(when (fboundp 'org-dynamic-block-define)
  (org-dynamic-block-define "timecard" #'org-timecard-insert-dblock))

(provide 'org-timecard)

;;; org-timecard.el ends here
