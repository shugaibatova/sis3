
import json
import os
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3
from botocore.exceptions import ClientError

REGION = os.environ["REGION"]
QUEUE_URL = os.environ["QUEUE_URL"]
TOPIC_ARN = os.environ["TOPIC_ARN"]
TABLE_NAME = os.environ["TABLE_NAME"]

sqs = boto3.client("sqs", region_name=REGION)
sns = boto3.client("sns", region_name=REGION)
table = boto3.resource("dynamodb", region_name=REGION).Table(TABLE_NAME)


def log(msg):
    print(msg, flush=True)


def handle(message):
    receipt = message["ReceiptHandle"]
    attempt = message["Attributes"].get("ApproximateReceiveCount", "?")
    try:
        event = json.loads(message["Body"])
        dedup_key = event["eventId"]         
        log(f"RECEIVED dedup_key={dedup_key} attempt={attempt}")

       
        if event.get("payload", {}).get("poison"):
            raise ValueError("poison message, processing failed")

        try:
            table.put_item(
                Item={"pk": dedup_key, "ttl": int(time.time()) + 86400},
                ConditionExpression="attribute_not_exists(pk)",
            )
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                log(f"DUPLICATE skipped dedup_key={dedup_key}")
                sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt)
                return
            raise

        log(f"PROCESSED dedup_key={dedup_key} type={event.get('type')} payload={event.get('payload')}")
        sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt)
    except Exception as e:  
        log(f"ERROR attempt={attempt} error={e}")


def consume_forever():
    log("consumer started")
    while True:
        try:
            resp = sqs.receive_message(
                QueueUrl=QUEUE_URL,
                MaxNumberOfMessages=5,
                WaitTimeSeconds=10,
                AttributeNames=["ApproximateReceiveCount"],
            )
        except Exception as e:
            log(f"receive failed: {e}")
            time.sleep(5)
            continue
        for m in resp.get("Messages", []):
            handle(m)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode() if not isinstance(body, bytes) else body
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/publish":
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            event = json.loads(self.rfile.read(length) or b"{}")
            event.setdefault("eventId", str(uuid.uuid4()))
            event.setdefault("type", "OrderCreated")
            event.setdefault("payload", {})
            sns.publish(TopicArn=TOPIC_ARN, Message=json.dumps(event))
            log(f"PUBLISHED eventId={event['eventId']}")
            self._send(200, {"published": event["eventId"]})
        except Exception as e:
            self._send(500, {"error": str(e)})

    def log_message(self, *args):  
        pass


if __name__ == "__main__":
    threading.Thread(target=consume_forever, daemon=True).start()
    log("http server on :80")
    ThreadingHTTPServer(("0.0.0.0", 80), Handler).serve_forever()
