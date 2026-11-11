output "state_bucket_name" {
  value = module.state_backend.bucket_name
}

output "iam_policy_arns" {
  value = module.state_backend.iam_policy_arns
}

output "iam_policy_documents" {
  value = module.state_backend.iam_policy_documents
}

# Contenu de environments/prod/backend.s3.tfbackend (fichier non versionné) :
#   terraform output -raw backend_config > ../environments/prod/backend.s3.tfbackend
output "backend_config" {
  value = "bucket = \"${module.state_backend.bucket_name}\"\n"
}
