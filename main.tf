# Add the necessary providers here for aws and archive from hashicorp
terraform {
  required_providers {
    aws = {
        source = "hashicorp/aws"
        version = "4.64.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.3.0"
    }
  }
  required_version = "~> 1.4.5"
}

# Set the aws region here
provider "aws" {
    region = var.aws_region
}

# Create the bucket in whic user uploads the files into
resource "aws_s3_bucket" "partner_data_bucket" {
  bucket = "partner_data_bucket"
}

# Create an iam policy that will allow getobject from the bucket in which the partner uploads data daily
resource "aws_iam_policy" "partner_data_bucket_policy" {
    name = "partner_data_bucket_policy"
    policy = jsonencode({
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::partner_data_bucket/*"
        }]
    })
}

# Create a sqs policy
resource "aws_iam_policy" "partner_sqs_policy" {
    name = "partner_sqs_policy"
    policy = jsonencode({
        "Version": "2012-10-17",
        "Statement": [{
          "Effect": "Allow",
          "Principal": {
                "Service": "lambda.amazonaws.com"
            },
          "Action": [
            "sqs:ReceiveMessage",
            "sqs:SendMessage",
            "sqs:GetQueueAttributes"
            ],
          "Resource": "arn:aws:sqs:::partner_sqs_queue"
        }]
    })
}

# Create a dynamodb policy
resource "aws_iam_policy" "partner_dynamodb_policy" {
    name = "partner_dynamodb_policy"
    policy = jsonencode({
        "Version": "2012-10-17",
        "Statement": [
          {
          "Effect": "Allow",
          "Principal": {
                "Service": "lambda.amazonaws.com"
            },
          "Action": [
            "dynamodb:BatchGetItem",
				    "dynamodb:GetItem",
				    "dynamodb:Query",
				    "dynamodb:Scan",
				    "dynamodb:BatchWriteItem",
				    "dynamodb:PutItem",
            "dynamodb:UpdateItem"
            ],
          "Resource": "arn:aws:dynamodb:::table/partner_table"
        }
        ]
    })
}

# Create an iam role for lambda service in order to attach it to the policy created above
resource "aws_iam_role" "lambda_role" {
    name = "lambda_role"
    assume_role_policy = jsonencode({
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Allow",
            "Principal": {
                "Service": "lambda.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
        ]
    }) 
}

# Attach the lambda role to the s3 bucket policy
resource "aws_iam_policy_attachment" "partner_data_bucket_policy_attachment" {
    name = "partner_data_bucket_policy_attachment"
    roles = [ aws_iam_role.lambda_role.name ]
    policy_arn = aws_iam_policy.partner_data_bucket_policy.arn
}

# Attach the lambda role to the dynamodb policy
resource "aws_iam_policy_attachment" "partner_dynamodb_policy_attachment" {
    name = "partner_dynamodb_policy_attachment"
    roles = [ aws_iam_role.lambda_role.name ]
    policy_arn = aws_iam_policy.partner_dynamodb_policy.arn
}

# Attach the lambda role to the dynamodb policy
resource "aws_iam_policy_attachment" "partner_sqs_policy_attachment" {
    name = "partner_sqs_policy_attachment"
    roles = [ aws_iam_role.lambda_role.name ]
    policy_arn = aws_iam_policy.partner_sqs_policy.arn
}

# Allow Lambda to perform basic execution 
resource "aws_iam_policy_attachment" "lambda_role_policy_attachment" {
    name = "lambda_role_policy_attachment"
    roles = [ aws_iam_role.lambda_role.name ]
    policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Install python requirements
resource "null_resource" "install_python_dependencies" {
  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/create_pkg.sh"

    environment = {
      source_code_path = var.path_source_code
      function_name = var.function_name
      path_module = path.module
      runtime = var.runtime
      path_cwd = path.cwd
    }
  }
}

# create the pzip file
data "archive_file" "create_dist_pkg" {
  depends_on = ["null_resource.install_python_dependencies"]
  source_dir = "${path.cwd}/lambda_dist_pkg/"
  output_path = var.output_path
  type = "zip"
}
resource "aws_lambda_function" "aws_lambda_test" {
  function_name = "partner_data_lambda"
  runtime = var.runtime
  handler = "partner_processor.lambda_handler"

  role = aws_iam_role.lambda_role.name
  memory_size = 128
  timeout = 300

  depends_on = [null_resource.install_python_dependencies]
  source_code_hash = data.archive_file.create_dist_pkg.output_base64sha256
  filename = data.archive_file.create_dist_pkg.output_path
}


# This has to come after the zip file is ready and uploaded to AWS ans specify the lambda entry point here
resource "aws_lambda_function" "partner_lambda" {
    function_name = "partner_data_lambda"
    filename = "${path.module}/partner-data-processor.zip"
    
}

# Set permission for Lambda function Execution
resource "aws_lambda_permission" "lambda_allow_bucket" {
  statement_id = "AllowExecutionFromS3Bucket"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.partner_lambda.arn
  principal = "s3.amazonaws.com"
  source_arn = aws_s3_bucket.partner_data_bucket.arn
}

# Define the trigger details here
resource "aws_s3_bucket_notification" "lambda_notification" {
    bucket = aws_s3_bucket.partner_data_bucket.id

    lambda_function {
        lambda_function_arn = aws_lambda_function.partner_lambda.arn
        events = [ "s3:ObjectCreated:*" ]
    }

    depends_on = [
      aws_lambda_permission.lambda_allow_bucket
    ]
}

resource "aws_cloudwatch_log_group" "partner_cloudwatch" {
  name = "/aws/lambda/${aws_lambda_function.partner_lambda.function_name}"
}
# Create Dynamo db and make lambda write to it
resource "aws_dynamodb_table" "partner-dynamodb-table" {
  name           = "partner_table"
  billing_mode   = "PROVISIONED"
  read_capacity  = 20
  write_capacity = 20
  hash_key       = "uuid"
}

# Create SQS and make lambda write to it
resource "aws_sqs_queue" "partner-sqs-queue" {
  name                      = "partner_sqs_queue"
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.terraform_queue_deadletter.arn
    maxReceiveCount     = 4
  })
}