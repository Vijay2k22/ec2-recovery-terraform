import logging
import os
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
REGION = "ap-south-1"
IDS = [x.strip() for x in os.environ["INSTANCE_IDS"].split(",")]
TARGET_GROUP = os.environ["TARGET_GROUP_ARN"]
TOPIC = os.environ["SNS_TOPIC_ARN"]
NAMESPACE = os.environ["METRIC_NAMESPACE"]
if len(IDS) != 2 or len(set(IDS)) != 2:
    raise ValueError("Set two distinct Mumbai EC2 instance IDs")

ec2 = boto3.client("ec2", region_name=REGION)
elb = boto3.client("elbv2", region_name=REGION)
cw = boto3.client("cloudwatch", region_name=REGION)
sns = boto3.client("sns", region_name=REGION)
# In-memory state resets if the monitor container restarts.
pending = {}  # iid -> monotonic timestamp of accepted start request
cooldown = {}  # iid -> earliest retry timestamp
last_state = {}


def stamp():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def alert(subject, name, iid, detail):
    message = (f"EC2 name: {name}\nInstance ID: {iid}\nRegion: {REGION}\n"
               f"Time: {stamp()}\n{detail}")
    try:
        sns.publish(TopicArn=TOPIC, Subject=subject, Message=message)
        logging.warning("Email notification published: %s (%s)", subject, iid)
        return True
    except Exception:
        logging.exception("SNS publish failed for %s", iid)
        return False


def metric(iid, stopped):
    try:
        cw.put_metric_data(Namespace=NAMESPACE, MetricData=[{
            "MetricName": "EC2Stopped",
            "Dimensions": [{"Name": "InstanceId", "Value": iid}],
            "Value": int(stopped), "Unit": "Count", "StorageResolution": 1,
        }])
    except Exception:
        logging.exception("CloudWatch metric failed for %s", iid)


def healthy(iid):
    checks = ec2.describe_instance_status(InstanceIds=[iid])["InstanceStatuses"]
    if not checks or checks[0]["InstanceStatus"]["Status"] != "ok" or checks[0]["SystemStatus"]["Status"] != "ok":
        return False
    targets = elb.describe_target_health(
        TargetGroupArn=TARGET_GROUP, Targets=[{"Id": iid}]
    )["TargetHealthDescriptions"]
    return bool(targets and targets[0]["TargetHealth"]["State"] == "healthy")


while True:
    try:
        rows = [i for r in ec2.describe_instances(InstanceIds=IDS)["Reservations"]
                for i in r["Instances"]]
        found = {i["InstanceId"]: i for i in rows}
        for iid in IDS:
            if iid not in found:
                logging.error("Instance %s missing from DescribeInstances", iid)
                continue
            item = found[iid]
            state = item["State"]["Name"]
            name = next((t["Value"] for t in item.get("Tags", [])
                         if t["Key"] == "Name"), iid)
            metric(iid, state in ("stopping", "stopped"))
            if last_state.get(iid) != state:
                logging.info("%s (%s): %s", name, iid, state)
                last_state[iid] = state
            if iid in pending:
                if state == "running" and healthy(iid):
                    if alert("EC2 has started successfully and remains healthy", name, iid,
                             "EC2 instance and system checks are OK; ALB target is healthy."):
                        del pending[iid]
                        cooldown.pop(iid, None)
                    continue
                if time.monotonic() - pending[iid] >= 900:
                    if alert("EC2 recovery needs attention", name, iid,
                             "The EC2 and ALB checks did not become healthy within 15 minutes."):
                        del pending[iid]
                        cooldown[iid] = time.monotonic() + 300
                    continue
                continue
            if state != "stopped" or time.monotonic() < cooldown.get(iid, 0):
                continue
            # A stopped state alone cannot establish why the instance stopped.
            if not alert("EC2 has stopped - reason not yet determined", name, iid,
                         "EC2 state is stopped. The agent will request a start."):
                cooldown[iid] = time.monotonic() + 30
                continue
            try:
                ec2.start_instances(InstanceIds=[iid])
                pending[iid] = time.monotonic()
                alert("AI Agent identified the EC2 and requested a start", name, iid,
                      "StartInstances was accepted. Waiting for EC2 and ALB health checks.")
            except ClientError:
                logging.exception("StartInstances failed for %s", iid)
                alert("EC2 recovery needs attention", name, iid, "StartInstances failed; inspect monitor logs.")
                cooldown[iid] = time.monotonic() + 300
    except Exception:
        logging.exception("Monitoring cycle failed")
    time.sleep(10)
