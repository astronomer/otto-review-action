"""Small intentionally broken DAG used to trigger the otto-review-action e2e run.

This DAG carries a couple of obvious issues that Otto's reviewer persona
should flag:

- `schedule_interval` is a deprecated parameter; use `schedule`.
- `timedelta` is used but never imported.

If Otto flags none of these, the prompt or the verdict-extraction path
regressed.
"""

from airflow.sdk import DAG, task
from datetime import datetime


with DAG(
    dag_id="buggy_sales_dag",
    start_date=datetime(2026, 1, 1),
    schedule_interval=timedelta(days=1),
    catchup=False,
):

    @task
    def summarize_sales(region: str) -> dict:
        return {"region": region, "total": 0}

    summarize_sales("us-east")
