AWSTemplateFormatVersion: "2010-09-09" 
Description: >
  Lambda triggered on S3 changes. Writes structured JSON logs to CloudWatch and
  emits custom CloudWatch metrics (ProcessedObjects, ProcessedBytes).
  Avoids create-time circular validation by omitting SourceArn on Lambda permission.

Parameters:   # Input parameters for the template
  Handler:  # Lambda handler parameter
    Type: String #  Type of the parameter
    Default: index.handler  # Default handler
  Runtime:  # Lambda runtime parameter
    Type: String  # Type of the parameter
    Default: python3.9  # Default runtime
  MetricNamespace:  # Custom metric namespace parameter
    Type: String  # Type of the parameter
    Default: S3LambdaMonitor # Default value
    Description: CloudWatch custom metric namespace  # Description of the parameter

Resources:  # Resources to be created
  LambdaExecutionRole:  # IAM Role for Lambda execution
    Type: AWS::IAM::Role # Type of the resource
    Properties: # Properties of the resource
      AssumeRolePolicyDocument: # Trust policy
        Version: "2012-10-17" # Version of the policy
        Statement: # Policy statements
          - Effect: Allow  # Effect of the statement
            Principal:  # Principal definition
              Service:  # Service principal
                - lambda.amazonaws.com  # Lambda service principal
            Action: sts:AssumeRole  # Action allowed
      Path: "/"  # Path for the role
      ManagedPolicyArns:  # Managed policies attached to the role
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole # Basic Lambda execution role
        - arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess # Read-only access to S3
      Policies: # Inline policies
        - PolicyName: PutCloudWatchMetrics # Policy name
          PolicyDocument: # Policy document
            Version: "2012-10-17" # Version of the policy
            Statement: # Policy statements
              - Sid: PutMetrics  # Statement ID
              - Effect: Allow # Effect of the statement
                Action:  #  Actions allowed
                  - cloudwatch:PutMetricData #    Put metric data action
                Resource: "*"   # Resource scope

  SampleFunction:  # Lambda function resource
    Type: AWS::Lambda::Function  # Type of the resource
    DependsOn: LambdaExecutionRole  # Dependency on the IAM Role
    Properties:  # Properties of the resource
      Handler: !Ref Handler  # Handler reference
      Runtime: !Ref Runtime  # Runtime reference
      Role: !GetAtt LambdaExecutionRole.Arn  # IAM Role ARN reference
      Timeout: 60  # Timeout in seconds
      MemorySize: 256  # Memory size in MB
      Environment:  # Environment variables
        Variables:   # Environment variable definitions
          METRIC_NAMESPACE: !Ref MetricNamespace  # Custom metric namespace
      Code:  # Lambda function code
        ZipFile: |   #  Inline code
          import json    # Import necessary modules
          import logging  
          import os
          import boto3
          from base64 import b64decode

          logger = logging.getLogger()
          logger.setLevel(logging.INFO)

          cw = boto3.client("cloudwatch")
          METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "S3LambdaMonitor")

          def put_metrics(objects_count, total_bytes, error_count=0):
              metrics = []
              if objects_count is not None:
                  metrics.append({
                      "MetricName": "ProcessedObjects",
                      "Unit": "Count",
                      "Value": objects_count
                  })
              if total_bytes is not None:
                  metrics.append({
                      "MetricName": "ProcessedBytes",
                      "Unit": "Bytes",
                      "Value": total_bytes
                  })
              if error_count:
                  metrics.append({
                      "MetricName": "ProcessingErrors",
                      "Unit": "Count",
                      "Value": error_count
                  })
              if metrics:
                  try:
                      cw.put_metric_data(
                          Namespace=METRIC_NAMESPACE,
                          MetricData=metrics
                      )
                  except Exception as e:
                      logger.exception("Failed to put custom metric data: %s", e)

          def extract_record_info(record):
              s3 = record.get("s3", {})
              bucket = s3.get("bucket", {}).get("name")
              obj = s3.get("object", {})
              key = obj.get("key")
              size = obj.get("size") if isinstance(obj.get("size"), int) else None
              event_time = record.get("eventTime")
              event_name = record.get("eventName")
              principal = record.get("userIdentity", {})
              return {
                  "bucket": bucket,
                  "key": key,
                  "size": size,
                  "eventTime": event_time,
                  "eventName": event_name,
                  "principal": principal
              }

          def handler(event, context):
              """
              Structured logging:
                - top-level 's3_event' JSON contains array of record summaries
                - logs also include raw event for debugging
              Emits custom metrics:
                - ProcessedObjects (count)
                - ProcessedBytes (sum of sizes when available)
                - ProcessingErrors (if exceptions occur)
              """
              try:
                  logger.info(json.dumps({"message": "Lambda invoked", "event_summary": {"records": len(event.get("Records", []))}}))
                  logger.info(json.dumps({"raw_event": event}))
                  
                  records = event.get("Records", [])
                  summary_items = []
                  total_bytes = 0
                  counted = 0

                  for r in records:
                      info = extract_record_info(r)
                      summary_items.append(info)
                      if info.get("size") is not None:
                          total_bytes += info["size"]
                      # Some S3 event types (Delete) may not include size; still count the record
                      counted += 1

                      # synthetic failure trigger for testing alarm (key containing 'fail')
                      if info.get("key") and "fail" in info["key"]:
                          raise RuntimeError("Synthetic failure for testing CloudWatch Alarm")

                  # Structured log entry (Logs Insights friendly)
                  structured = {
                      "s3_event": {
                          "record_count": counted,
                          "total_bytes": total_bytes,
                          "records": summary_items
                      }
                  }
                  logger.info(json.dumps(structured))

                  # Put custom metrics (safe if counts are zero)
                  put_metrics(objects_count=counted, total_bytes=total_bytes, error_count=0)

                  return {"statusCode": 200, "body": json.dumps({"processed": counted, "bytes": total_bytes})}

              except Exception as exc:
                  logger.exception("Processing failed: %s", exc)
                  # report error metric
                  try:
                      put_metrics(objects_count=0, total_bytes=0, error_count=1)
                  except Exception:
                      logger.exception("Failed to emit error metric")
                  # re-raise so Lambda records an invocation error (and existing Error alarm fires)
                  raise

  LambdaLogGroup: # CloudWatch Log Group for Lambda
    Type: AWS::Logs::LogGroup  #  Type of the resource
    DependsOn: SampleFunction  # Dependency on the Lambda function
    Properties:  # Properties of the resource
      LogGroupName: !Sub "/aws/lambda/${SampleFunction}"  # Log group name
      RetentionInDays: 30  # Retention period in days

  SampleBucket:  #  S3 Bucket resource
    Type: AWS::S3::Bucket  # Type of the resource
    Properties:  # Properties of the resource
      NotificationConfiguration:  # Notification configuration
        LambdaConfigurations:  # Lambda event configurations
          - Event: "s3:ObjectCreated:*" # Event type
            Function: !GetAtt SampleFunction.Arn  # Lambda function ARN
          - Event: "s3:ObjectRemoved:*" # Event type
            Function: !GetAtt SampleFunction.Arn  # Lambda function ARN
          - Event: "s3:ObjectRestore:Completed"  # Event type
            Function: !GetAtt SampleFunction.Arn  # Lambda function ARN
          - Event: "s3:ObjectTagging:*"  # Event type
            Function: !GetAtt SampleFunction.Arn  # Lambda function ARN

  S3InvokePermission:  #  Lambda permission for S3 to invoke
    Type: AWS::Lambda::Permission  # Type of the resource
    Properties:  # Properties of the resource
      FunctionName: !Ref SampleFunction  # Lambda function reference
      Action: "lambda:InvokeFunction"  # Action allowed
      Principal: "s3.amazonaws.com"  # S3 service principal
      # SourceArn intentionally omitted to avoid circular dependency at stack creation time.

  # CloudWatch Alarm: trigger when Lambda reports >= 1 error in 1 minute
  LambdaErrorsAlarm:   #  CloudWatch Alarm for Lambda errors
    Type: AWS::CloudWatch::Alarm  # Type of the resource
    Properties:  # Properties of the resource
      AlarmName: !Sub "${AWS::StackName}-LambdaErrorsAlarm"  # Alarm name
      AlarmDescription: "Alarm when Lambda reports one or more Errors in a 1-minute period"  # Alarm description
      Namespace: "AWS/Lambda"  # Metric namespace
      MetricName: "Errors"  # Metric name
      Dimensions: # Metric dimensions
        - Name: FunctionName  # Dimension name
          Value: !Ref SampleFunction  # Dimension value
      Statistic: Sum  # Statistic type
      Period: 60  # Period in seconds
      EvaluationPeriods: 1  # Number of evaluation periods
      ComparisonOperator: GreaterThanOrEqualToThreshold  # Comparison operator
      Threshold: 1  # Threshold value
      TreatMissingData: "notBreaching" # How to treat missing data
      # add SNS topic ARNs here to get notifications
      # AlarmActions: []

Outputs:  # Output values from the template
  LambdaArn:  # Lambda function ARN output
    Description: Lambda function ARN  # Description of the output
    Value: !GetAtt SampleFunction.Arn  # Lambda function ARN reference

  LambdaName:  # Lambda function name output
    Description: Auto-generated Lambda function name # Description of the output
    Value: !Ref SampleFunction  # Lambda function name reference

  BucketName:  # S3 Bucket name output
    Description: S3 bucket name (any change triggers Lambda ? structured logs + metrics)  # Description of the output
    Value: !Ref SampleBucket  # S3 Bucket name reference

  MetricNamespace:  # Custom metric namespace output
    Description: Custom metric namespace where ProcessedObjects/ProcessedBytes are emitted # Description of the output
    Value: !Ref MetricNamespace # Custom metric namespace reference

  LambdaErrorsAlarmName:  # Lambda Errors Alarm name output
    Description: CloudWatch alarm name for Lambda errors # Description of the output
    Value: !Ref LambdaErrorsAlarm # Lambda Errors Alarm reference
