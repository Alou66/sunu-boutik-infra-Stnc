# Exemple Ansible Vault

Créer le vault :

    ansible-vault create inventory/group_vars/all/vault.yml

Contenu exemple (valeurs FICTIVES, à remplacer puis chiffrer) :

    ghcr_username: votre_user_github
    ghcr_token: CHANGE_ME
    db_user: CHANGE_ME
    db_password: CHANGE_ME
    secret_key: CHANGE_ME_GENERATE_RANDOM
    admin_password: CHANGE_ME
    smtp_password: ""

`admin_email`, `frontend_url`, `cors_origins`, `smtp_user` et
`nginx_certbot_email` ne sont pas des secrets : voir `VAULT_STRUCTURE.md`.
