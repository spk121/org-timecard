;;; org-timecard-tests.el --- Tests for org-timecard -*- lexical-binding: t; -*-

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Run with `make test', or:
;;
;;     emacs --batch -Q -L . --eval "(setq load-prefer-newer t)" \
;;           -l org-timecard-tests.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org-timecard)

(defconst org-timecard-tests--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding the tests and example.org.")

(defmacro org-timecard-tests--with-org (text &rest body)
  "Run BODY in a temporary Org buffer containing TEXT."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((org-inhibit-startup t))
       (delay-mode-hooks (org-mode)))
     (insert ,text)
     (goto-char (point-min))
     ,@body))

(defun org-timecard-tests--time (string)
  "Parse STRING, such as \"2026-11-10 09:00\", as local time."
  (org-time-string-to-time string))

(defun org-timecard-tests--entry (start end &optional task)
  "Make an entry from START to END for TASK."
  (list :start (org-timecard-tests--time start)
        :end (org-timecard-tests--time end)
        :task (or task "T") :charge "C" :labor "L"))

(defconst org-timecard-tests--week "\
* Work
** Project1
*** Weekly IPT Meeting                                        :A122:status:
:LOGBOOK:
CLOCK: [2026-11-13 Fri 08:22]--[2026-11-13 Fri 19:21] => 10:59
:END:
*** Prepare SRR                                             :A124:analysis:
:LOGBOOK:
CLOCK: [2026-11-13 Fri 08:01]--[2026-11-13 Fri 08:22] =>  0:21
CLOCK: [2026-11-10 Tue 09:23]--[2026-11-10 Tue 19:23] => 10:00
:END:
*** Ethics training                                      :TRN100:training:
** Project2
*** Laser Assemblies                                          :B101:design:
:LOGBOOK:
CLOCK: [2026-11-12 Thu 09:25]--[2026-11-12 Thu 19:25] => 10:00
:END:
")

;;;; Collecting entries

(ert-deftest org-timecard-entries-sorted-with-tags ()
  (org-timecard-tests--with-org org-timecard-tests--week
    (let ((entries (org-timecard--entries)))
      (should (equal (mapcar (lambda (e) (plist-get e :task)) entries)
                     '("Prepare SRR" "Laser Assemblies" "Prepare SRR"
                       "Weekly IPT Meeting")))
      (should (equal (mapcar (lambda (e) (plist-get e :charge)) entries)
                     '("A124" "B101" "A124" "A122")))
      (should (equal (mapcar (lambda (e) (plist-get e :labor)) entries)
                     '("analysis" "design" "analysis" "status")))
      (should (equal (plist-get (car entries) :start)
                     (org-timecard-tests--time "2026-11-10 09:23")))
      (should (equal (plist-get (car entries) :end)
                     (org-timecard-tests--time "2026-11-10 19:23"))))))

(ert-deftest org-timecard-entries-ignore-running-clock ()
  (org-timecard-tests--with-org "\
* Task :X1:ops:
CLOCK: [2026-11-10 Tue 09:00]
CLOCK: [2026-11-09 Mon 09:00]--[2026-11-09 Mon 10:00] =>  1:00
"
    (should (= 1 (length (org-timecard--entries))))))

(ert-deftest org-timecard-entries-missing-tags ()
  (org-timecard-tests--with-org "\
* No tags
CLOCK: [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:00] =>  1:00
* One tag :X1:
CLOCK: [2026-11-10 Tue 10:00]--[2026-11-10 Tue 11:00] =>  1:00
"
    (let ((entries (org-timecard--entries)))
      (should (equal (plist-get (nth 0 entries) :charge) "(none)"))
      (should (equal (plist-get (nth 0 entries) :labor) "(none)"))
      (should (equal (plist-get (nth 1 entries) :charge) "X1"))
      (should (equal (plist-get (nth 1 entries) :labor) "(none)")))))

(ert-deftest org-timecard-entries-tags-not-inherited ()
  (org-timecard-tests--with-org "\
* Parent :P1:parent:
** Child :C1:child:
CLOCK: [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:00] =>  1:00
"
    (let ((e (car (org-timecard--entries))))
      (should (equal (plist-get e :charge) "C1"))
      (should (equal (plist-get e :labor) "child")))))

(ert-deftest org-timecard-entries-respect-narrowing ()
  (org-timecard-tests--with-org org-timecard-tests--week
    (re-search-forward "^\\*\\* Project2")
    (org-narrow-to-subtree)
    (should (equal (mapcar (lambda (e) (plist-get e :task))
                           (org-timecard--entries))
                   '("Laser Assemblies")))))

(ert-deftest org-timecard-entries-empty ()
  (org-timecard-tests--with-org "* Nothing clocked :X1:ops:\n"
    (should (null (org-timecard--entries)))))

;;;; Splitting by day

(ert-deftest org-timecard-day-slices-one-day ()
  (should (equal (org-timecard--day-slices
                  (org-timecard-tests--time "2026-11-10 09:00")
                  (org-timecard-tests--time "2026-11-10 10:30"))
                 '(("2026-11-10 Tue" . 5400.0)))))

(ert-deftest org-timecard-day-slices-across-midnight ()
  (should (equal (org-timecard--day-slices
                  (org-timecard-tests--time "2026-11-10 22:00")
                  (org-timecard-tests--time "2026-11-11 02:30"))
                 '(("2026-11-10 Tue" . 7200.0)
                   ("2026-11-11 Wed" . 9000.0)))))

(ert-deftest org-timecard-day-slices-three-days ()
  (should (equal (org-timecard--day-slices
                  (org-timecard-tests--time "2026-11-10 23:00")
                  (org-timecard-tests--time "2026-11-12 01:00"))
                 '(("2026-11-10 Tue" . 3600.0)
                   ("2026-11-11 Wed" . 86400.0)
                   ("2026-11-12 Thu" . 3600.0)))))

(ert-deftest org-timecard-day-slices-ending-at-midnight ()
  (should (equal (org-timecard--day-slices
                  (org-timecard-tests--time "2026-11-10 23:00")
                  (org-timecard-tests--time "2026-11-11 00:00"))
                 '(("2026-11-10 Tue" . 3600.0)))))

(ert-deftest org-timecard-day-slices-empty-range ()
  (let ((time (org-timecard-tests--time "2026-11-10 09:00")))
    (should (null (org-timecard--day-slices time time)))))

;;;; Tables

(ert-deftest org-timecard-log-table ()
  (org-timecard-tests--with-org org-timecard-tests--week
    (should
     (equal
      (org-timecard--log-table (org-timecard--entries))
      '(("Time" "Task" "Charge" "Labor")
        hline
        ("[2026-11-10 Tue 09:23]--[2026-11-10 Tue 19:23]"
         "Prepare SRR" "A124" "analysis")
        ("[2026-11-12 Thu 09:25]--[2026-11-12 Thu 19:25]"
         "Laser Assemblies" "B101" "design")
        ("[2026-11-13 Fri 08:01]--[2026-11-13 Fri 08:22]"
         "Prepare SRR" "A124" "analysis")
        ("[2026-11-13 Fri 08:22]--[2026-11-13 Fri 19:21]"
         "Weekly IPT Meeting" "A122" "status"))))))

(ert-deftest org-timecard-log-table-escapes-pipes ()
  "A \"|\" in a task name must not start a new table column."
  (org-timecard-tests--with-org "\
* Design A | B :X1:ops:
CLOCK: [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:00] =>  1:00
"
    (should (equal (org-timecard--render 'log) "\
| Time                                           | Task               | Charge | Labor |
|------------------------------------------------+--------------------+--------+-------|
| [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:00] | Design A \\vert{} B | X1     | ops   |"))))

(ert-deftest org-timecard-charge-table ()
  (org-timecard-tests--with-org org-timecard-tests--week
    (should
     (equal
      (org-timecard--pivot-table (org-timecard--entries) :charge)
      '(("Day" "A122" "A124" "B101" "Total")
        hline
        ("2026-11-10 Tue" "" "10.00" "" "10.00")
        ("2026-11-12 Thu" "" "" "10.00" "10.00")
        ("2026-11-13 Fri" "10.98" "0.35" "" "11.33")
        hline
        ("Total" "10.98" "10.35" "10.00" "31.33"))))))

(ert-deftest org-timecard-labor-table ()
  (org-timecard-tests--with-org org-timecard-tests--week
    (should
     (equal
      (org-timecard--pivot-table (org-timecard--entries) :labor)
      '(("Day" "analysis" "design" "status" "Total")
        hline
        ("2026-11-10 Tue" "10.00" "" "" "10.00")
        ("2026-11-12 Thu" "" "10.00" "" "10.00")
        ("2026-11-13 Fri" "0.35" "" "10.98" "11.33")
        hline
        ("Total" "10.35" "10.00" "10.98" "31.33"))))))

(ert-deftest org-timecard-pivot-sums-tasks-sharing-a-charge ()
  (org-timecard-tests--with-org "\
* One :X1:ops:
CLOCK: [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:00] =>  1:00
* Two :X1:design:
CLOCK: [2026-11-10 Tue 10:00]--[2026-11-10 Tue 12:30] =>  2:30
"
    (should (equal (org-timecard--pivot-table (org-timecard--entries) :charge)
                   '(("Day" "X1" "Total")
                     hline
                     ("2026-11-10 Tue" "3.50" "3.50")
                     hline
                     ("Total" "3.50" "3.50"))))))

(ert-deftest org-timecard-pivot-splits-at-midnight ()
  (org-timecard-tests--with-org "\
* Night shift :X1:ops:
CLOCK: [2026-11-10 Tue 22:00]--[2026-11-11 Wed 02:30] =>  4:30
"
    (should (equal (org-timecard--pivot-table (org-timecard--entries) :charge)
                   '(("Day" "X1" "Total")
                     hline
                     ("2026-11-10 Tue" "2.00" "2.00")
                     ("2026-11-11 Wed" "2.50" "2.50")
                     hline
                     ("Total" "4.50" "4.50"))))))

(ert-deftest org-timecard-entries-priority ()
  (org-timecard-tests--with-org "\
* A :X1:ops:high:
CLOCK: [2026-11-10 Tue 08:00]--[2026-11-10 Tue 09:00] =>  1:00
* B :X1:ops:low:
CLOCK: [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:00] =>  1:00
* C :X1:ops:medium:
CLOCK: [2026-11-10 Tue 10:00]--[2026-11-10 Tue 11:00] =>  1:00
* D :X1:ops:
CLOCK: [2026-11-10 Tue 11:00]--[2026-11-10 Tue 12:00] =>  1:00
* E :X1:ops:HIGH:
CLOCK: [2026-11-10 Tue 12:00]--[2026-11-10 Tue 13:00] =>  1:00
* F :X1:ops:urgent:
CLOCK: [2026-11-10 Tue 13:00]--[2026-11-10 Tue 14:00] =>  1:00
* G
CLOCK: [2026-11-10 Tue 14:00]--[2026-11-10 Tue 15:00] =>  1:00
"
    (should (equal (mapcar (lambda (e) (plist-get e :priority))
                           (org-timecard--entries))
                   '("high" "low" "medium" "medium" "high" "medium"
                     "medium")))))

(ert-deftest org-timecard-priority-constants ()
  (should (equal org-timecard-priorities '("high" "medium" "low")))
  (should (equal org-timecard-default-priority "medium")))

(ert-deftest org-timecard-priority-table ()
  (org-timecard-tests--with-org "\
* A :X1:ops:high:
CLOCK: [2026-11-10 Tue 08:00]--[2026-11-10 Tue 09:00] =>  1:00
CLOCK: [2026-11-11 Wed 08:00]--[2026-11-11 Wed 12:00] =>  4:00
* B :X1:ops:low:
CLOCK: [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:00] =>  1:00
* C :X1:ops:
CLOCK: [2026-11-10 Tue 10:00]--[2026-11-10 Tue 12:00] =>  2:00
"
    (should (equal (org-timecard--priority-table (org-timecard--entries))
                   '(("Day" "High" "Medium" "Low")
                     hline
                     ("2026-11-10 Tue" "25%" "50%" "25%")
                     ("2026-11-11 Wed" "100%" "" "")
                     hline
                     ("All days" "62%" "25%" "12%"))))))

(ert-deftest org-timecard-priority-table-defaults-to-medium ()
  (org-timecard-tests--with-org org-timecard-tests--week
    (should (equal (org-timecard--priority-table (org-timecard--entries))
                   '(("Day" "High" "Medium" "Low")
                     hline
                     ("2026-11-10 Tue" "" "100%" "")
                     ("2026-11-12 Thu" "" "100%" "")
                     ("2026-11-13 Fri" "" "100%" "")
                     hline
                     ("All days" "" "100%" ""))))))

(ert-deftest org-timecard-priority-table-splits-at-midnight ()
  (org-timecard-tests--with-org "\
* A :X1:ops:high:
CLOCK: [2026-11-10 Tue 23:00]--[2026-11-11 Wed 01:00] =>  2:00
* B :X1:ops:low:
CLOCK: [2026-11-11 Wed 01:00]--[2026-11-11 Wed 04:00] =>  3:00
"
    (should (equal (org-timecard--priority-table (org-timecard--entries))
                   '(("Day" "High" "Medium" "Low")
                     hline
                     ("2026-11-10 Tue" "100%" "" "")
                     ("2026-11-11 Wed" "25%" "" "75%")
                     hline
                     ("All days" "40%" "" "60%"))))))

(ert-deftest org-timecard-percent-format ()
  (should (equal (org-timecard--percent 0 100) ""))
  (should (equal (org-timecard--percent 0 0) ""))
  (should (equal (org-timecard--percent 1 3) "33%"))
  (let ((org-timecard-percent-format "%.1f%%"))
    (should (equal (org-timecard--percent 1 3) "33.3%"))))

(ert-deftest org-timecard-dblock-priority ()
  (org-timecard-tests--with-org "\
* A :X1:ops:high:
CLOCK: [2026-11-10 Tue 08:00]--[2026-11-10 Tue 09:00] =>  1:00
* B :X1:ops:
CLOCK: [2026-11-10 Tue 09:00]--[2026-11-10 Tue 12:00] =>  3:00
#+BEGIN: timecard :report priority
#+END:
"
    (org-update-all-dblocks)
    (should (string-match-p
             (regexp-quote "\
| Day            | High | Medium | Low |
|----------------+------+--------+-----|
| 2026-11-10 Tue |  25% |    75% |     |
|----------------+------+--------+-----|
| All days       |  25% |    75% |     |
#+END:")
             (buffer-string)))))

(ert-deftest org-timecard-hours-format ()
  (should (equal (org-timecard--hours 0) ""))
  (should (equal (org-timecard--hours 5400) "1.50"))
  (let ((org-timecard-hours-format "%.1f"))
    (should (equal (org-timecard--hours 5400) "1.5"))))

;;;; Overlaps and gaps

(ert-deftest org-timecard-gap-minutes-is-240 ()
  (should (= org-timecard-gap-minutes 240)))

(ert-deftest org-timecard-notes-none-when-adjacent ()
  (should (null (org-timecard--log-notes
                 (list (org-timecard-tests--entry
                        "2026-11-10 08:00" "2026-11-10 09:00")
                       (org-timecard-tests--entry
                        "2026-11-10 09:00" "2026-11-10 10:00"))))))

(ert-deftest org-timecard-notes-none-for-one-or-no-entries ()
  (should (null (org-timecard--log-notes nil)))
  (should (null (org-timecard--log-notes
                 (list (org-timecard-tests--entry
                        "2026-11-10 08:00" "2026-11-10 09:00"))))))

(ert-deftest org-timecard-notes-overlap ()
  (should
   (equal
    (org-timecard--log-notes
     (list (org-timecard-tests--entry
            "2026-11-10 08:00" "2026-11-10 12:00" "A")
           (org-timecard-tests--entry
            "2026-11-10 11:30" "2026-11-10 13:00" "B")))
    (list (concat "WARNING: overlap of 0:30, "
                  "[2026-11-10 Tue 11:30]--[2026-11-10 Tue 12:00], "
                  "between \"A\" and \"B\"")))))

(ert-deftest org-timecard-notes-overlap-contained ()
  "A range inside a longer one overlaps for its whole length.
The range after it is still compared with the longer one."
  (should
   (equal
    (org-timecard--log-notes
     (list (org-timecard-tests--entry
            "2026-11-10 08:00" "2026-11-10 12:00" "A")
           (org-timecard-tests--entry
            "2026-11-10 09:00" "2026-11-10 10:00" "B")
           (org-timecard-tests--entry
            "2026-11-10 12:00" "2026-11-10 13:00" "C")))
    (list (concat "WARNING: overlap of 1:00, "
                  "[2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:00], "
                  "between \"A\" and \"B\"")))))

(ert-deftest org-timecard-notes-identical-ranges-overlap ()
  (let ((notes (org-timecard--log-notes
                (list (org-timecard-tests--entry
                       "2026-11-10 08:00" "2026-11-10 09:00" "A")
                      (org-timecard-tests--entry
                       "2026-11-10 08:00" "2026-11-10 09:00" "B")))))
    (should (= 1 (length notes)))
    (should (string-prefix-p "WARNING: overlap of 1:00, " (car notes)))))

(ert-deftest org-timecard-notes-short-gap ()
  (should
   (equal
    (org-timecard--log-notes
     (list (org-timecard-tests--entry
            "2026-11-10 08:00" "2026-11-10 13:00" "A")
           (org-timecard-tests--entry
            "2026-11-10 13:45" "2026-11-10 17:00" "B")))
    (list (concat "Note: gap of 0:45, "
                  "[2026-11-10 Tue 13:00]--[2026-11-10 Tue 13:45], "
                  "between \"A\" and \"B\"")))))

(ert-deftest org-timecard-notes-gap-threshold ()
  "A gap is noted only when shorter than `org-timecard-gap-minutes'."
  (let ((first (org-timecard-tests--entry
                "2026-11-10 08:00" "2026-11-10 12:00")))
    ;; 3:59
    (should (= 1 (length (org-timecard--log-notes
                          (list first
                                (org-timecard-tests--entry
                                 "2026-11-10 15:59" "2026-11-10 17:00"))))))
    ;; 4:00 exactly
    (should (null (org-timecard--log-notes
                   (list first
                         (org-timecard-tests--entry
                          "2026-11-10 16:00" "2026-11-10 17:00")))))
    ;; Overnight
    (should (null (org-timecard--log-notes
                   (list first
                         (org-timecard-tests--entry
                          "2026-11-11 08:00" "2026-11-11 12:00")))))))

(ert-deftest org-timecard-notes-short-gap-across-midnight ()
  (let ((notes (org-timecard--log-notes
                (list (org-timecard-tests--entry
                       "2026-11-10 20:00" "2026-11-10 23:30")
                      (org-timecard-tests--entry
                       "2026-11-11 00:30" "2026-11-11 04:00")))))
    (should (= 1 (length notes)))
    (should (string-prefix-p "Note: gap of 1:00, " (car notes)))))

;;;; Rendering, commands and dynamic blocks

(ert-deftest org-timecard-render-log-without-notes ()
  (org-timecard-tests--with-org "\
* Task :X1:ops:
CLOCK: [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:00] =>  1:00
"
    (should (equal (org-timecard--render 'log) "\
| Time                                           | Task | Charge | Labor |
|------------------------------------------------+------+--------+-------|
| [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:00] | Task | X1     | ops   |"))))

(ert-deftest org-timecard-render-log-with-notes ()
  (org-timecard-tests--with-org "\
* A :X1:ops:
CLOCK: [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:00] =>  1:00
* B :X2:ops:
CLOCK: [2026-11-10 Tue 09:30]--[2026-11-10 Tue 11:00] =>  1:30
CLOCK: [2026-11-10 Tue 11:15]--[2026-11-10 Tue 12:00] =>  0:45
"
    (let ((text (org-timecard--render 'log)))
      (should (string-match-p "^- WARNING: overlap of 0:30, " text))
      (should (string-match-p "^- Note: gap of 0:15, " text)))))

(ert-deftest org-timecard-render-notes-only-in-log ()
  (org-timecard-tests--with-org "\
* A :X1:ops:
CLOCK: [2026-11-10 Tue 09:00]--[2026-11-10 Tue 10:00] =>  1:00
* B :X2:ops:
CLOCK: [2026-11-10 Tue 09:30]--[2026-11-10 Tue 11:00] =>  1:30
"
    (should-not (string-match-p "WARNING" (org-timecard--render 'charge)))
    (should-not (string-match-p "WARNING" (org-timecard--render 'labor)))))

(ert-deftest org-timecard-render-unknown-report ()
  (org-timecard-tests--with-org org-timecard-tests--week
    (should-error (org-timecard--render 'bogus) :type 'user-error)))

(ert-deftest org-timecard-dblock ()
  (org-timecard-tests--with-org (concat org-timecard-tests--week "\
* Reports
#+BEGIN: timecard :report charge
#+END:
")
    (org-update-all-dblocks)
    (let ((once (buffer-string)))
      (should (string-match-p
               (regexp-quote "\
#+BEGIN: timecard :report charge
| Day            |  A122 |  A124 |  B101 | Total |
|----------------+-------+-------+-------+-------|
| 2026-11-10 Tue |       | 10.00 |       | 10.00 |
| 2026-11-12 Thu |       |       | 10.00 | 10.00 |
| 2026-11-13 Fri | 10.98 |  0.35 |       | 11.33 |
|----------------+-------+-------+-------+-------|
| Total          | 10.98 | 10.35 | 10.00 | 31.33 |
#+END:")
               once))
      ;; Updating again must not change anything.
      (org-update-all-dblocks)
      (should (equal once (buffer-string))))))

(ert-deftest org-timecard-dblock-defaults-to-log ()
  (org-timecard-tests--with-org (concat org-timecard-tests--week "\
#+BEGIN: timecard
#+END:
")
    (org-update-all-dblocks)
    (should (string-match-p "^| Time +| Task +| Charge | Labor +|$"
                            (buffer-string)))))

(ert-deftest org-timecard-report-command ()
  (let ((org-timecard-buffer-name "*Org Timecard test*"))
    (unwind-protect
        (save-window-excursion
          (org-timecard-tests--with-org org-timecard-tests--week
            (org-timecard-report))
          (with-current-buffer org-timecard-buffer-name
            (should (derived-mode-p 'org-mode))
            (let ((text (buffer-string)))
              (should (string-match-p "^\\* Time log$" text))
              (should (string-match-p
                       "^\\* Hours by day and charge number$" text))
              (should (string-match-p
                       "^\\* Hours by day and labor type$" text))
              (should (string-match-p
                       "^\\* Share of each day by priority$" text))
              (should (string-match-p "^| Day +| analysis " text))
              (should (string-match-p "^| Day +| High | Medium | Low |$"
                                      text)))))
      (when (get-buffer org-timecard-buffer-name)
        (kill-buffer org-timecard-buffer-name)))))

(ert-deftest org-timecard-report-command-needs-org-buffer ()
  (with-temp-buffer
    (should-error (org-timecard-log-report) :type 'user-error)))

;;;; Reminder

(ert-deftest org-timecard-reminder-minutes-is-60 ()
  (should (= org-timecard-reminder-minutes 60)))

(ert-deftest org-timecard-reminder-mode-timer ()
  (unwind-protect
      (progn
        (org-timecard-reminder-mode 1)
        (let ((timer org-timecard--reminder-timer))
          (should (memq timer timer-idle-list))
          (should (= 3600 (float-time (timer--time timer))))
          (should (timer--repeat-delay timer))
          (should (eq (timer--function timer) #'org-timecard--reminder-first))
          ;; Turning it on twice must not leave a second timer behind.
          (org-timecard-reminder-mode 1)
          (should-not (memq timer timer-idle-list))
          (setq timer org-timecard--reminder-timer)
          (org-timecard-reminder-mode -1)
          (should-not (memq timer timer-idle-list))
          (should-not org-timecard--reminder-timer)))
    (org-timecard-reminder-mode -1)))

(ert-deftest org-timecard-reminder-repeats-while-idle ()
  "The reminder repeats every 60 minutes until the idle stretch ends."
  (let ((flashes 0)
        (idle nil))
    (cl-letf (((symbol-function 'org-timecard-flash)
               (lambda () (cl-incf flashes)))
              ((symbol-function 'current-idle-time)
               (lambda () (and idle (seconds-to-time idle)))))
      (unwind-protect
          (progn
            ;; 60 minutes idle: flash, and a repeating timer starts.
            (org-timecard--reminder-first)
            (should (= flashes 1))
            (let ((timer org-timecard--reminder-repeat-timer))
              (should (memq timer timer-list))
              (should (= 3600 (timer--repeat-delay timer)))
              (should (eq (timer--function timer)
                          #'org-timecard--reminder-again))
              ;; 120 and 180 minutes idle: flash again each time.
              (setq idle 7200)
              (org-timecard--reminder-again)
              (setq idle 10800)
              (org-timecard--reminder-again)
              (should (= flashes 3))
              (should (memq timer timer-list))
              ;; There was input 50 minutes ago: no flash, repeating stops.
              (setq idle 3000)
              (org-timecard--reminder-again)
              (should (= flashes 3))
              (should-not (memq timer timer-list))
              (should-not org-timecard--reminder-repeat-timer))
            ;; A new stretch starts over, with a single repeating timer.
            (org-timecard--reminder-first)
            (let ((timer org-timecard--reminder-repeat-timer))
              (org-timecard--reminder-first)
              (should-not (memq timer timer-list)))
            (should (= flashes 5))
            ;; Not idle at all: repeating stops.
            (setq idle nil)
            (org-timecard--reminder-again)
            (should (= flashes 5))
            (should-not org-timecard--reminder-repeat-timer))
        (org-timecard--reminder-stop-repeat)))))

(ert-deftest org-timecard-reminder-mode-off-stops-repeat ()
  (cl-letf (((symbol-function 'org-timecard-flash) #'ignore))
    (unwind-protect
        (progn
          (org-timecard-reminder-mode 1)
          (org-timecard--reminder-first)
          (let ((timer org-timecard--reminder-repeat-timer))
            (org-timecard-reminder-mode -1)
            (should-not (memq timer timer-list))
            (should-not org-timecard--reminder-repeat-timer)))
      (org-timecard-reminder-mode -1))))

(ert-deftest org-timecard-flash-restores-colors ()
  "A flash swaps the colors an even number of times, twice per flash."
  (let ((org-timecard-reminder-flash-seconds 0)
        (swaps 0))
    (cl-letf (((symbol-function 'invert-face)
               (lambda (face &optional _frame)
                 (should (eq face 'default))
                 (cl-incf swaps))))
      (let ((inhibit-message t))
        (org-timecard-flash))
      (sleep-for 0.1))
    (should (= swaps (* 2 org-timecard-reminder-flashes)))
    (should (= swaps 4))))

(ert-deftest org-timecard-example-file-is-current ()
  "The dynamic blocks saved in example.org match what the code produces."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "example.org" org-timecard-tests--dir))
    (let ((org-inhibit-startup t))
      (delay-mode-hooks (org-mode)))
    (let ((saved (buffer-string)))
      (org-update-all-dblocks)
      (should (equal saved (buffer-string))))))

(provide 'org-timecard-tests)

;;; org-timecard-tests.el ends here
