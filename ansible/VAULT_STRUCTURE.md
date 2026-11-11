# Structure Ansible Vault

Créer localement (non commité, voir `.gitignore`) :

    ansible-vault create inventory/group_vars/all/vault.yml

Modèle : `inventory/group_vars/all/vault.yml.example`.

## Secrets attendus (vault.yml)

| Variable         | Usage                                              |
|------------------|----------------------------------------------------|
| `ghcr_username`  | Compte GHCR (pull des images privées)              |
| `ghcr_token`     | PAT GHCR, scope `read:packages`                    |
| `db_user`        | Utilisateur PostgreSQL                             |
| `db_password`    | Mot de passe PostgreSQL                            |
| `secret_key`     | Clé JWT de l'API (32 caractères minimum)           |
| `admin_password` | Mot de passe du compte `admin_email`               |
| `smtp_password`  | Mot de passe d'application SMTP (vide si SMTP off) |

## Configuration non sensible (hors vault)

| Variable              | Fichier                     | Obligatoire              |
|-----------------------|-----------------------------|--------------------------|
| `admin_email`         | `group_vars/all/vars.yml`   | oui                      |
| `frontend_url`        | `group_vars/all/vars.yml`   | oui (défini)             |
| `cors_origins`        | `group_vars/all/vars.yml`   | non (= `frontend_url`)   |
| `smtp_user`           | `group_vars/all/vars.yml`   | non (vide = SMTP off)    |
| `nginx_certbot_email` | `group_vars/frontend.yml`   | oui (1re émission TLS)   |

Ne pas redéfinir ces clés dans le vault : `vault.yml` est chargé après
`vars.yml` et les écraserait. Les rôles `fastapi` et `nginx` vérifient ces
variables par des assertions avant tout changement sur les hôtes.

Ne jamais commiter `vault.yml` en clair. Mot de passe : `vault_password_file`
(`ansible.cfg`) ou `--ask-vault-pass`.
