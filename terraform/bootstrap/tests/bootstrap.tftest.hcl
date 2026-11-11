# Câblage du bootstrap, hors ligne (provider AWS simulé, aucun appel AWS).
# Lancer : terraform init -backend=false && terraform test
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}

run "bucket_state_par_defaut" {
  command = plan

  assert {
    condition     = output.state_bucket_name == "sunu-boutik-tfstate-111122223333"
    error_message = "Bucket de state attendu : sunu-boutik-tfstate-<ID compte>."
  }
  assert {
    condition     = output.backend_config == "bucket = \"sunu-boutik-tfstate-111122223333\"\n"
    error_message = "backend_config doit contenir uniquement le nom du bucket."
  }
}

run "region_imposee" {
  command = plan
  variables {
    aws_region = "eu-west-1"
  }
  expect_failures = [var.aws_region]
}
