# org extract

- `employees.csv`: `id,name,manager_id,department_id` as of the start of the
  year. An empty `manager_id` means the person reports to nobody.
- `transfers.csv`: `employee_id,new_manager_id,effective_date`. On its
  effective date a transfer replaces the employee's manager. Transfers with an
  effective date after the date you are asking about have not happened yet.
- `departments.json`: department ids and names.
