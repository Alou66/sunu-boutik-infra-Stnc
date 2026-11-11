# Vérifie le JSON IAM réellement généré (aws_iam_policy_document est
# calculé localement par le provider). Provider réel mais isolé : faux
# identifiants, aucune validation, endpoints vers 127.0.0.1:9 (tout appel
# réseau échouerait), données de compte surchargées. Aucun appel à AWS.
provider "aws" {
  region                      = "eu-north-1"
  access_key                  = "mock_access_key"
  secret_key                  = "mock_secret_key"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true

  endpoints {
    iam = "http://127.0.0.1:9"
    s3  = "http://127.0.0.1:9"
    sts = "http://127.0.0.1:9"
  }
}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "111122223333" }
}

override_data {
  target = data.aws_partition.current
  values = { partition = "aws" }
}

variables {
  project_name = "sunu-boutik"
  state_keys   = ["sunu-boutik/prod/terraform.tfstate"]
}

run "json_state_rw" {
  command = plan

  assert {
    condition = {
      for s in jsondecode(data.aws_iam_policy_document.state_rw.json).Statement :
      s.Sid => join(",", concat([s.Effect], sort(flatten([s.Action])), sort(flatten([s.Resource]))))
      } == {
      ListStateBucket = "Allow,s3:ListBucket,arn:aws:s3:::sunu-boutik-tfstate-111122223333"
      ReadWriteState  = "Allow,s3:GetObject,s3:PutObject,arn:aws:s3:::sunu-boutik-tfstate-111122223333/sunu-boutik/prod/terraform.tfstate"
      ManageLockFile  = "Allow,s3:DeleteObject,s3:GetObject,s3:PutObject,arn:aws:s3:::sunu-boutik-tfstate-111122223333/sunu-boutik/prod/terraform.tfstate.tflock"
    }
    error_message = "JSON state-rw inattendu."
  }
}

run "json_state_ro_et_recovery" {
  command = plan

  assert {
    condition = sort(flatten([
      for s in jsondecode(data.aws_iam_policy_document.state_ro.json).Statement : s.Action
    ])) == sort(["s3:GetObject", "s3:ListBucket"])
    error_message = "JSON state-ro inattendu."
  }
  assert {
    condition = sort(flatten([
      for s in jsondecode(data.aws_iam_policy_document.state_recovery.json).Statement : s.Action
    ])) == sort(["s3:GetObjectVersion", "s3:ListBucketVersions"])
    error_message = "JSON state-recovery inattendu."
  }
  assert {
    condition = alltrue(flatten([
      for d in [data.aws_iam_policy_document.state_rw, data.aws_iam_policy_document.state_ro, data.aws_iam_policy_document.state_recovery] : [
        for s in jsondecode(d.json).Statement : s.Effect == "Allow" && !can(s.NotAction) && !can(s.NotResource)
      ]
    ]))
    error_message = "Politiques proposées : Allow explicites uniquement, sans NotAction/NotResource."
  }
}

run "json_politique_bucket" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Effect == "Deny"
    ])
    error_message = "La politique du bucket ne doit contenir que des refus (aucun accès accordé)."
  }
  assert {
    condition = [
      for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement :
      s.Condition.Bool["aws:SecureTransport"] if s.Sid == "DenyInsecureTransport"
    ] == ["false"]
    error_message = "HTTP doit être refusé."
  }
  assert {
    condition     = jsondecode(aws_s3_bucket_policy.state.policy) == jsondecode(data.aws_iam_policy_document.bucket.json)
    error_message = "La politique appliquée doit être celle relue ici."
  }
}
