terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region = "us-east-1"
}

# DynamoDB

resource "aws_dynamodb_table" "sequences" {
  name           = "sequences"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "pt"
  range_key      = "id"

  attribute {
    name = "pt"
    type = "N"
  }

  attribute {
    name = "id"
    type = "N"
  }
}

resource "aws_dynamodb_table_item" "first" {
  table_name = aws_dynamodb_table.sequences.name
  hash_key   = aws_dynamodb_table.sequences.hash_key
  range_key  = aws_dynamodb_table.sequences.range_key
  item       = <<ITEM
{
  "pt": { "N": "0" },
  "id": { "N": "0" },
  "value": { "N": "0" }
}
ITEM
}

resource "aws_dynamodb_table_item" "second" {
  table_name = aws_dynamodb_table.sequences.name
  hash_key   = aws_dynamodb_table.sequences.hash_key
  range_key  = aws_dynamodb_table.sequences.range_key
  item       = <<ITEM
{
  "pt": { "N": "0" },
  "id": { "N": "1" },
  "value": { "N": "1" }
}
ITEM
}

# Lambda

data "aws_iam_policy_document" "add" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "add" {
  assume_role_policy = data.aws_iam_policy_document.add.json
}

data "archive_file" "lambda-placeholder" {
  type        = "zip"
  output_path = "${path.module}/lambda-placeholder.zip"

  source {
    content  = "exports.handler = async (event) => {};"
    filename = "index.js"
  }
}

resource "aws_lambda_function" "add" {
  function_name = "add"
  role          = aws_iam_role.add.arn
  runtime       = "nodejs12.x"
  handler       = "index.handler"
  filename      = data.archive_file.lambda-placeholder.output_path

  lifecycle {
    ignore_changes = [filename]
  }
}

# State machine

data "aws_iam_policy_document" "state-machine" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "state-machine" {
  assume_role_policy = data.aws_iam_policy_document.state-machine.json
}

resource "aws_iam_role_policy_attachment" "execute-lambda" {
  role       = aws_iam_role.state-machine.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaRole"
}

data "aws_iam_policy_document" "access-dynamodb" {
  statement {
    actions = ["dynamodb:Query", "dynamodb:PutItem"]
    effect  = "Allow"

    resources = [
      aws_dynamodb_table.sequences.arn
    ]
  }
}

resource "aws_iam_policy" "access-dynamodb" {
  policy = data.aws_iam_policy_document.access-dynamodb.json
}

resource "aws_iam_role_policy_attachment" "access-dynamodb" {
  role       = aws_iam_role.state-machine.id
  policy_arn = aws_iam_policy.access-dynamodb.arn
}

resource "aws_sfn_state_machine" "state-machine" {
  definition = <<EOF
  {
    "Comment": "A description of my state machine",
    "StartAt": "Parallel",
    "States": {
      "Parallel": {
        "Type": "Parallel",
        "Branches": [
          {
            "StartAt": "Get first",
            "States": {
              "Get first": {
                "Type": "Task",
                "End": true,
                "Parameters": {
                  "TableName": "sequences",
                  "ScanIndexForward": false,
                  "KeyConditionExpression": "pt = :pt",
                  "ExpressionAttributeValues": {
                    ":pt": {
                      "N": "0"
                    }
                  },
                  "Limit": 2
                },
                "Resource": "arn:aws:states:::aws-sdk:dynamodb:query",
                "ResultSelector": {
                  "value.$": "$.Items[1].value.N"
                }
              }
            }
          },
          {
            "StartAt": "Get second",
            "States": {
              "Get second": {
                "Type": "Task",
                "End": true,
                "Parameters": {
                  "TableName": "sequences",
                  "ScanIndexForward": false,
                  "KeyConditionExpression": "pt = :pt",
                  "ExpressionAttributeValues": {
                    ":pt": {
                      "N": "0"
                    }
                  },
                  "Limit": 1
                },
                "Resource": "arn:aws:states:::aws-sdk:dynamodb:query",
                "ResultSelector": {
                  "id.$": "$.Items[0].id.N",
                  "value.$": "$.Items[0].value.N"
                }
              }
            }
          }
        ],
        "Next": "Pass"
      },
      "Pass": {
        "Type": "Pass",
        "Parameters": {
          "id.$": "$[1].id",
          "first.$": "$[0].value",
          "second.$": "$[1].value"
        },
        "Next": "Lambda Invoke"
      },
      "Lambda Invoke": {
        "Type": "Task",
        "Resource": "arn:aws:states:::lambda:invoke",
        "OutputPath": "$.Payload",
        "Parameters": {
          "Payload.$": "$",
          "FunctionName": "${aws_lambda_function.add.arn}:$LATEST"
        },
        "Retry": [
          {
            "ErrorEquals": [
              "Lambda.ServiceException",
              "Lambda.AWSLambdaException",
              "Lambda.SdkClientException"
            ],
            "IntervalSeconds": 2,
            "MaxAttempts": 6,
            "BackoffRate": 2
          }
        ],
        "Next": "Persist"
      },
      "Persist": {
        "Type": "Task",
        "Resource": "arn:aws:states:::dynamodb:putItem",
        "Parameters": {
          "TableName": "sequences",
          "Item": {
            "pt": {
              "N": "0"
            },
            "id": {
              "N.$": "$.id"
            },
            "value": {
              "N.$": "$.value"
            }
          }
        },
        "End": true
      }
    }
  }
  EOF
  name       = "add"
  role_arn   = aws_iam_role.state-machine.arn
}