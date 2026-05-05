"""Reference DAG used by the otto-review-action e2e setup.

This DAG is intentionally well-formed: imports complete, schedule is set with
the current parameter name, task functions are atomic, and the data flow
between tasks is explicit. Otto should not raise concerns about this file.
"""

from airflow.sdk import DAG, task
from datetime import datetime

import pandas as pd


with DAG(
    dag_id="clean_etl_dag",
    start_date=datetime(2026, 1, 1),
    schedule="@daily",
    catchup=False,
    tags=["e2e", "otto-review"],
    default_args={"owner": "astronomer", "retries": 2},
):

    @task
    def extract(file_path: str) -> pd.DataFrame:
        return pd.read_csv(file_path)

    @task
    def transform(raw_data: pd.DataFrame) -> pd.DataFrame:
        return raw_data.loc[raw_data["items_sold"] < 100, :]

    @task
    def load(cleaned_data: pd.DataFrame, file_path: str) -> None:
        cleaned_data.to_csv(file_path, index=False)

    raw = extract("raw_data.csv")
    cleaned = transform(raw)
    load(cleaned, "cleaned_data.csv")
