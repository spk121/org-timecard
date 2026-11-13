# org-timecard

Emacs Lisp for a weekly timecard kept in Org mode. You clock time
against tasks with the normal Org clock commands, and `org-timecard`
builds the reports.

## Recording time

Each task is a headline with two tags, in this order: the charge
number, then the labor type. An optional third tag gives the priority:
`high`, `medium` or `low`. A task with no priority tag is `medium`.

```org
* Work
** Project2
*** Electrical Engineering
**** Laser Assemblies                                         :B101:design:
:LOGBOOK:
CLOCK: [2026-11-12 Thu 09:25]--[2026-11-12 Thu 19:25] => 10:00
:END:
**** Prepare SRR                                       :A124:analysis:high:
:LOGBOOK:
CLOCK: [2026-11-10 Tue 09:23]--[2026-11-10 Tue 19:23] => 10:00
:END:
```

Org tags are written as one run, `:B101:design:`, not as separate
`:B101: :design:` groups. `C-c C-q` sets them, and `C-c C-x C-i` /
`C-c C-x C-o` clock in and out. See `example.org` for a full week.

## Installing

Put `org-timecard.el` somewhere on your `load-path` and add to your
init file:

```elisp
(add-to-list 'load-path "~/src/org-timecard")
(require 'org-timecard)
```

## Reports

Run these in the timecard's Org buffer. The tables open in the
`*Org Timecard*` buffer.

| Command                      | Report                                                    |
|------------------------------|-----------------------------------------------------------|
| `org-timecard-log-report`    | Every time range, oldest first: time, task, charge, labor |
| `org-timecard-charge-report` | Hours per day for each charge number                      |
| `org-timecard-labor-report`  | Hours per day for each labor type                         |
| `org-timecard-priority-report` | Percentage of each day spent on each priority           |
| `org-timecard-report`        | All four                                                  |

The same tables can live in the Org file as dynamic blocks. Press
`C-c C-c` on the `#+BEGIN` line to refresh one, or run
`org-update-all-dblocks` for all of them:

```org
#+BEGIN: timecard :report charge
| Day            |  A122 |  A124 |  B100 |  B101 | Total |
|----------------+-------+-------+-------+-------+-------|
| 2026-11-10 Tue |       | 10.00 |       |       | 10.00 |
| 2026-11-11 Wed |       |       | 10.00 |       | 10.00 |
| 2026-11-12 Thu |       |       |       | 10.00 | 10.00 |
| 2026-11-13 Fri | 10.98 |  0.35 |       |       | 11.33 |
|----------------+-------+-------+-------+-------+-------|
| Total          | 10.98 | 10.35 | 10.00 | 10.00 | 41.33 |
#+END:
```

`:report` is `log`, `charge`, `labor` or `priority`. `org-timecard-insert-dblock`
inserts a block at point.

## Overlaps and gaps

Below its table, the log report lists two kinds of remark:

```org
- WARNING: overlap of 0:30, [2026-11-10 Tue 11:30]--[2026-11-10 Tue 12:00], between "A" and "B"
- Note: gap of 0:45, [2026-11-10 Tue 13:00]--[2026-11-10 Tue 13:45], between "B" and "B"
```

- A warning for each time range that overlaps an earlier one.
- A note for each gap shorter than `org-timecard-gap-minutes`, a
  constant set to 240. Gaps of that length or longer are taken to be
  time off between shifts and are not mentioned.

## Priority

The priority report gives, for each day, the share of that day's
clocked time spent on each priority. The last row is the share over
all days.

```org
| Day            | High | Medium | Low |
|----------------+------+--------+-----|
| 2026-11-10 Tue | 100% |        |     |
| 2026-11-11 Wed |      |   100% |     |
| 2026-11-12 Thu |      |   100% |     |
| 2026-11-13 Fri |   3% |        | 97% |
|----------------+------+--------+-----|
| All days       |  25% |    48% | 27% |
```

Percentages are rounded, so a row may add up to 99% or 101%; change
`org-timecard-percent-format` for more digits.

## Reminder

`org-timecard-reminder-mode` flashes the screen twice, and shows a
message, as a reminder to update the timecard. To turn it on at
startup:

```elisp
(org-timecard-reminder-mode 1)
```

The flash comes when Emacs has been idle, meaning no keyboard or mouse
input, for `org-timecard-reminder-minutes`, a constant set to 60. It
then repeats every 60 minutes for as long as Emacs stays idle. Any
input ends the idle stretch and starts the count again. `M-x org-timecard-flash` shows the flash on demand.

## Details

- Hours are decimal; change `org-timecard-hours-format` for a different
  precision.
- A clock that crosses midnight is split between the two days in the
  day reports.
- A clock that is still running is left out.
- A task missing its charge or labor tag is reported under `(none)`
  (`org-timecard-missing`).
- A third tag that is not `high`, `medium` or `low` counts as `medium`.
- Reports cover the accessible part of the buffer, so narrowing to a
  subtree (`C-x n s`) reports on that subtree alone.

## Tests

```bash
make test
```

runs the ERT suite in `org-timecard-tests.el`. `make compile`
byte-compiles `org-timecard.el` with warnings treated as errors.
