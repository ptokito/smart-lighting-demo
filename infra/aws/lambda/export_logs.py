"""
export_logs: move logs that are 24 hours old from CloudWatch Logs to S3.

Runs every hour (Amazon EventBridge schedule). Each run exports exactly one
hour of logs: the hour that has just become `EXPORT_AGE_HOURS` old. For
example, with the default of 24, the 15:00 run on Tuesday exports Monday
14:00 to 15:00. Over a day the hourly runs cover every hour exactly once.

Why this design
    The requirement is "logs older than 24 hours go to a dedicated S3 bucket".
    Recent logs stay searchable in New Relic (and in CloudWatch for 3 days)
    for troubleshooting; anything past 24 hours lands in an encrypted S3
    bucket with a lifecycle policy, which is the cheap, durable place for
    public-records retention.

Manual run for the demo (no need to wait a day):
    aws lambda invoke --function-name <name> --payload '{"age_hours": 0}' \
        --cli-binary-format raw-in-base64-out out.json
    With age_hours 0 it exports the hour that just ended.

AWS allows only one export task per account to be running at a time, so the
function retries if another export is in progress, then waits for its own
task to finish so the result shows up in this function's logs.
"""

import json
import os
import time
from datetime import datetime, timedelta, timezone

import boto3

logs = boto3.client("logs")

LOG_GROUP = os.environ["LOG_GROUP"]
BUCKET = os.environ["BUCKET"]
PREFIX = os.environ.get("PREFIX", "cloudwatch-exports")
DEFAULT_AGE_HOURS = int(os.environ.get("EXPORT_AGE_HOURS", "24"))


def handler(event, context):
    age_hours = int((event or {}).get("age_hours", DEFAULT_AGE_HOURS))

    # The window is one whole clock hour, ending `age_hours` before the start
    # of the current hour.
    this_hour = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    window_end = this_hour - timedelta(hours=age_hours)
    window_start = window_end - timedelta(hours=1)

    # Objects land under a dated path, e.g.
    # cloudwatch-exports/2026/10/27/14/<task id>/<stream>/000000.gz
    destination_prefix = f"{PREFIX}/{window_start:%Y/%m/%d/%H}"

    task_id = None
    for attempt in range(1, 11):
        try:
            task_id = logs.create_export_task(
                taskName=f"smart-lighting-{window_start:%Y%m%d%H}",
                logGroupName=LOG_GROUP,
                fromTime=int(window_start.timestamp() * 1000),   # milliseconds since epoch
                to=int(window_end.timestamp() * 1000),
                destination=BUCKET,
                destinationPrefix=destination_prefix,
            )["taskId"]
            break
        except logs.exceptions.LimitExceededException:
            # Another export is still running in this account; wait and retry.
            print(f"Another export is running, retry {attempt}/10 in 15s")
            time.sleep(15)
    if task_id is None:
        raise RuntimeError("Could not start the export: another export kept running")

    # Wait (up to 2 minutes) for the export to finish. Together with the
    # retries above this stays inside the 5-minute Lambda timeout.
    status = "PENDING"
    for _ in range(24):
        task = logs.describe_export_tasks(taskId=task_id)["exportTasks"][0]
        status = task["status"]["code"]
        if status in ("COMPLETED", "FAILED", "CANCELLED"):
            break
        time.sleep(5)

    result = {
        "taskId": task_id,
        "status": status,
        "logGroup": LOG_GROUP,
        "from": window_start.isoformat(),
        "to": window_end.isoformat(),
        "destination": f"s3://{BUCKET}/{destination_prefix}/",
    }
    # Printed as JSON so it is easy to read in CloudWatch and in New Relic.
    print(json.dumps(result))
    if status == "FAILED":
        raise RuntimeError(f"Export task failed: {json.dumps(result)}")
    return result
