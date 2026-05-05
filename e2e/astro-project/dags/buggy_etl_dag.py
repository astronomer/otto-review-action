"""Intentionally broken DAG used to verify otto-review-action surfaces issues.

This DAG mirrors the bugs the action's system prompt explicitly tells Otto to
flag. A working e2e run should produce inline comments calling out:

- `datetime` is used but never imported.
- `schedule_interval` is a deprecated parameter; use `schedule`.
- `cleaned_data` is referenced but never bound.
- `_raw_data` / `_cleaned_data` use a non-standard underscore prefix
  convention that doesn't match the rest of the project.

If Otto flags none of these, the prompt or the verdict-extraction path
regressed.
"""

from airflow.sdk import DAG, task

import pandas as pd


with DAG(
    dag_id="buggy_etl_dag",
    start_date=datetime(2026, 1, 1),
    schedule_interval=None,
):

    @task
    def extract(file_path):
        return pd.read_csv(file_path)

    @task
    def transform(_raw_data):
        return _raw_data.loc[_raw_data["items_sold"] < 100, :]

    @task
    def load(_cleaned_data, file_path):
        _cleaned_data.to_csv(file_path)

    raw_data = extract("raw_data.csv")
    transform(raw_data)
    load(cleaned_data, "cleaned_data.csv")
