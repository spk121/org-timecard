# org-timecard

Emacs Lisp for a weekly timecard kept in Org mode. You clock time
against tasks with the normal Org clock commands, and `org-timecard`
builds the reports.

## Recording time

Each task is a headline with exactly two tags, in this order: the
charge number, then the labor type.

```org
* Work
** Project2
*** Electrical Engineering
**** Laser Assemblies                                         :B101:design:
:LOGBOOK:
CLOCK: [2026-11-12 Thu 09:25]--[2026-11-12 Thu 19:25] => 10:00
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
| `org-timecard-report`        | All three                                                 |

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

`:report` is `log`, `charge` or `labor`. `org-timecard-insert-dblock`
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

## Details

- Hours are decimal; change `org-timecard-hours-format` for a different
  precision.
- A clock that crosses midnight is split between the two days in the
  day reports.
- A clock that is still running is left out.
- A task missing a tag is reported under `(none)`
  (`org-timecard-missing`).
- Reports cover the accessible part of the buffer, so narrowing to a
  subtree (`C-x n s`) reports on that subtree alone.

## Tests

```bash
make test
```

runs the ERT suite in `org-timecard-tests.el`. `make compile`
byte-compiles `org-timecard.el` with warnings treated as errors.
