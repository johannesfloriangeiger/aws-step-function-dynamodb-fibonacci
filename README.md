# AWS Step Function example

## Setup

```
PROFILE=...
aws configure --profile $PROFILE
```

## Install

### Terraform

```
AWS_SDK_LOAD_CONFIG=1 AWS_PROFILE=$PROFILE terraform init
AWS_SDK_LOAD_CONFIG=1 AWS_PROFILE=$PROFILE terraform apply
```

### Lambda

```
zip lambda.zip index.js \
    && aws --profile $PROFILE \
        lambda update-function-code \
        --function-name add \
        --zip-file fileb://lambda.zip \
        --publish \
    && rm lambda.zip
```

## Test

Run the state machine a few times and check the items in the `sequences` table: Every run adds the next item of the
Fibonacci sequence to the table.