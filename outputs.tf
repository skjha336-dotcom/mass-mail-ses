output "s3_bucket_name" {
  value = aws_s3_bucket.csv.bucket
}

output "lambda_function_name" {
  value = aws_lambda_function.mailer.function_name
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "nat_gateway_id" {
  value = aws_nat_gateway.nat.id
}

output "ses_sender_email_identity" {
  value = aws_ses_email_identity.sender.email
}

