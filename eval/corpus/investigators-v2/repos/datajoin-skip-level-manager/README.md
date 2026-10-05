# People directory export

Rules:

1. `people/people-*.csv` maps employee ids to names and status. Names are
   not unique; only `status = active` rows are current employees.
2. An employee's manager on date D is the `manager_id` of the row in
   `org/assignments/<year>/assignments-*.csv` with `from <= D < to` for that
   employee. If no row covers D, the head of the employee's department in
   `org/departments/heads.csv` is the manager for that date.
3. The skip-level manager on D is the manager, on D, of the manager on D.
