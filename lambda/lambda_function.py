
rashmi anand <rashmianand078@gmail.com>
22:54 (0 minutes ago)
to me

import boto3
import csv
import json
import urllib.parse

AWS_REGION = "ap-south-1"

# HARD-CODE sender (must be verified in SES)
SENDER_EMAIL = "rashmianand078@gmail.com"

EMAIL_SUBJECT = "Test email from AWS Lambda (SES)"
EMAIL_BODY_TEMPLATE = (
    "Hi {name},\n\n"
    "This is a test email sent from AWS Lambda using Amazon SES.\n\n"
    "Thanks!"
)

s3 = boto3.client("s3", region_name=AWS_REGION)
ses = boto3.client("ses", region_name=AWS_REGION)

def lambda_handler(event, context):
    print("✅ Lambda invoked. Event:")
    print(json.dumps(event))

    record = event["Records"][0]
    bucket = record["s3"]["bucket"]["name"]
    key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

    print(f"✅ S3 trigger detected: s3://{bucket}/{key}")

    obj = s3.get_object(Bucket=bucket, Key=key)
    raw = obj["Body"].read().decode("utf-8", errors="ignore")
    print("✅ Raw file preview (first 500 chars):")
    print(raw[:500])

    lines = raw.splitlines()
    if lines:
        lines[0] = lines[0].lstrip("\ufeff") # remove BOM

    reader = csv.DictReader(lines)
    print("✅ CSV headers detected:", reader.fieldnames)

    recipients = []
    for row in reader:
        email = (row.get("email") or "").strip()
        name = (row.get("name") or "").strip() or "there"
        if email:
            recipients.append((email, name))

    print(f"✅ Found {len(recipients)} recipients in CSV")
    if not recipients:
        return {"status": "no_recipients"}

    sent = 0
    failed = 0

    for (to_email, name) in recipients:
        try:
            body = EMAIL_BODY_TEMPLATE.format(name=name)
            print(f"➡️ Sending email: From={SENDER_EMAIL} To={to_email}")

            resp = ses.send_email(
                Source=SENDER_EMAIL,
                Destination={"ToAddresses": [to_email]},
                Message={
                    "Subject": {"Data": EMAIL_SUBJECT},
                    "Body": {"Text": {"Data": body}},
                },
            )

            print("✅ SES send_email succeeded. MessageId:", resp.get("MessageId"))
            sent += 1

        except Exception as e:
            print(f"❌ SES send failed for {to_email}: {str(e)}")
            failed += 1

    result = {"status": "done", "sent": sent, "failed": failed}
    print("✅ FINAL RESULT:", json.dumps(result))
    return result

