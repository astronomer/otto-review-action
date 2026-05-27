"""Second intentionally broken DAG used to verify otto-review-action surfaces issues.

This DAG packs several issues that the action's reviewer persona is tuned to
flag. A working e2e run should produce inline comments calling out:

- `datetime` is used but never imported.
- `schedule_interval` is a deprecated parameter; use `schedule`.
- `start_date` is in the future, which prevents the DAG from running.
- `inventory_df` is referenced in `load` but never bound at the DAG level.
- `_inventory` / `_filtered` use a non-standard underscore prefix convention
  that doesn't match the rest of the project.
- `pd` is used without importing pandas.
- The bare `except:` swallows every exception, including `KeyboardInterrupt`
  and `SystemExit`.

If Otto flags none of these, the prompt or the verdict-extraction path
regressed.
"""

from airflow.sdk import DAG, task


with DAG(
    dag_id="buggy_inventory_dag",
    start_date=datetime(2099, 1, 1),
    schedule_interval="@daily",
    catchup=False,
):

    @task
    def fetch_inventory(source_path):
        try:
            return pd.read_parquet(source_path)
        except:
            return None

    @task
    def filter_low_stock(_inventory, threshold):
        return _inventory.loc[_inventory["stock"] < threshold, :]

    @task
    def write_report(_filtered, destination_path):
        _filtered.to_csv(destination_path, index=False)

    inventory = fetch_inventory("s3://warehouse/inventory.parquet")
    filter_low_stock(inventory, 10)
    write_report(inventory_df, "s3://warehouse/low_stock.csv")
