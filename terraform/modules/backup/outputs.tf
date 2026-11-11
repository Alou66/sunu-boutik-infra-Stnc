output "bucket_name" { value = aws_s3_bucket.backups.bucket }
output "bucket_arn" { value = aws_s3_bucket.backups.arn }
output "database_role_name" { value = aws_iam_role.database.name }
output "database_instance_profile_name" { value = aws_iam_instance_profile.database.name }
