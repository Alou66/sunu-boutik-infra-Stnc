output "bucket_name" { value = aws_s3_bucket.state.bucket }
output "bucket_arn" { value = aws_s3_bucket.state.arn }

output "iam_policy_arns" {
  value = var.create_iam_policies ? {
    state_rw       = aws_iam_policy.state_rw[0].arn
    state_ro       = aws_iam_policy.state_ro[0].arn
    state_recovery = aws_iam_policy.state_recovery[0].arn
  } : null
}

# Documents JSON des politiques, pour relecture ou création manuelle.
output "iam_policy_documents" {
  value = {
    state_rw       = data.aws_iam_policy_document.state_rw.json
    state_ro       = data.aws_iam_policy_document.state_ro.json
    state_recovery = data.aws_iam_policy_document.state_recovery.json
  }
}
