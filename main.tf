############################
# Random suffix for S3 bucket uniqueness
############################
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  project_name = "mass-email"
  vpc_cidr = "10.0.0.0/16"
  public_cidr = "10.0.1.0/24"
  private_cidr = "10.0.2.0/24"
  az = "ap-south-1a"
  bucket_name = "${local.project_name}-csv-${random_id.suffix.hex}"
  lambda_name = "${local.project_name}-lambda"
  sender_email = "rashmianand078@gmail.com" # <-- CHANGE if you want
  upload_prefix = "uploads/"
}

############################
# VPC + Subnets
############################
resource "aws_vpc" "this" {
  cidr_block = local.vpc_cidr
  enable_dns_support = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.project_name}-vpc"
  }
}

resource "aws_subnet" "public" {
  vpc_id = aws_vpc.this.id
  cidr_block = local.public_cidr
  availability_zone = local.az
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.project_name}-public-subnet"
  }
}

resource "aws_subnet" "private" {
  vpc_id = aws_vpc.this.id
  cidr_block = local.private_cidr
  availability_zone = local.az

  tags = {
    Name = "${local.project_name}-private-subnet"
  }
}

############################
# Internet Gateway + Public Route Table
############################
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name = "${local.project_name}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name = "${local.project_name}-public-rt"
  }
}

resource "aws_route" "public_default" {
  route_table_id = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

############################
# NAT Gateway (EIP + NAT) + Private Route Table
############################
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name = "${local.project_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id = aws_subnet.public.id

  tags = {
    Name = "${local.project_name}-nat"
  }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name = "${local.project_name}-private-rt"
  }
}

resource "aws_route" "private_default" {
  route_table_id = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.nat.id
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

############################
# (Best practice) S3 Gateway Endpoint to avoid NAT data charges for S3 access
############################
resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id = aws_vpc.this.id
  service_name = "com.amazonaws.ap-south-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [aws_route_table.private.id]

  tags = {
    Name = "${local.project_name}-s3-gateway-endpoint"
  }
}

############################
# Security Group for Lambda (egress only)
############################
resource "aws_security_group" "lambda_sg" {
  name = "${local.project_name}-lambda-sg"
  description = "Lambda SG: outbound HTTPS only"
  vpc_id = aws_vpc.this.id

  # No inbound needed
  ingress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = []
    description = "No inbound"
  }

  egress {
    description = "HTTPS outbound"
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.project_name}-lambda-sg"
  }
}

############################
# S3 bucket to upload CSV
############################
resource "aws_s3_bucket" "csv" {
  bucket = local.bucket_name

  tags = {
    Name = "${local.project_name}-csv-bucket"
  }
}

resource "aws_s3_bucket_public_access_block" "csv" {
  bucket = aws_s3_bucket.csv.id
  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}

############################
# Lambda package (zip)
############################
data "archive_file" "lambda_zip" {
  type = "zip"
  source_dir = "${path.module}/lambda"
  output_path = "${path.module}/lambda.zip"
}

############################
# IAM role for Lambda
############################
resource "aws_iam_role" "lambda_role" {
  name = "${local.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

# CloudWatch Logs
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# VPC ENI permissions (Lambda creates ENIs automatically)
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Inline policy: S3 read + SES send
resource "aws_iam_role_policy" "lambda_app_policy" {
  name = "${local.project_name}-lambda-app-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read CSV from this bucket
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.csv.arn}/*"
      },
      # Optional but helpful
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.csv.arn
      },
      # SES send permissions (API calls)
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = "*"
      }
    ]
  })
}

############################
# SES Email identity (Terraform creates identity; verification is manual)
############################
resource "aws_ses_email_identity" "sender" {
  email = local.sender_email
}

############################
# Lambda function in private subnet
############################
resource "aws_lambda_function" "mailer" {
  function_name = local.lambda_name
  role = aws_iam_role.lambda_role.arn
  handler = "lambda_function.lambda_handler"
  runtime = "python3.11"
  filename = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout = 60
  memory_size = 256

  vpc_config {
    subnet_ids = [aws_subnet.private.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      # Hardcoded in code too, but useful for visibility
      SENDER_EMAIL = local.sender_email
      UPLOAD_PREFIX = local.upload_prefix
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_iam_role_policy.lambda_app_policy
  ]
}

############################
# Allow S3 to invoke Lambda
############################
resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id = "AllowExecutionFromS3Bucket"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mailer.function_name
  principal = "s3.amazonaws.com"
  source_arn = aws_s3_bucket.csv.arn
}

############################
# S3 Event Notification -> Lambda (trigger on uploads/ prefix)
############################
resource "aws_s3_bucket_notification" "notify_lambda" {
  bucket = aws_s3_bucket.csv.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.mailer.arn
    events = ["s3:ObjectCreated:Put", "s3:ObjectCreated:Post", "s3:ObjectCreated:CompleteMultipartUpload"]
    filter_prefix = local.upload_prefix
    filter_suffix = ".csv"
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke]
}

