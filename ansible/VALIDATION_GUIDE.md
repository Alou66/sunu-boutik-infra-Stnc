# Guide de validation locale

## Prérequis
- Terraform >= 1.6
- Ansible >= 2.9
- ansible-galaxy collection install community.docker
- Clé SSH configurée

## Étapes
1. Installer collections: `ansible-galaxy collection install community.docker`
2. Créer vault chiffré: `ansible-vault create inventory/group_vars/all/vault.yml` (ou utiliser --ask-vault-pass)
3. Compléter hosts.ini depuis terraform outputs
4. Compléter group_vars/all/vars.yml avec IPs privées
5. Créer terraform.tfvars avec key_name et allowed_ssh_cidr
6. Syntax check: `ansible-playbook --syntax-check playbooks/site.yml`
7. Terraform: `terraform fmt -check && terraform init -backend=false && terraform validate`
