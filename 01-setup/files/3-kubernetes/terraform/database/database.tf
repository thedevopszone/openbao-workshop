# database.tf — PostgreSQL Static Role: OpenBao rotiert das Passwort
# eines BESTEHENDEN DB-Users alle 24 h.
#
# Voraussetzung: Der zu rotierende User existiert bereits in Postgres
# (siehe 3-kubernetes.md, Abschnitt "OpenBao Secrets Operator" → Schritt 1).
# OpenBao verbindet sich mit einem Connection-User (hier: postgres-Superuser)
# und führt periodisch  ALTER USER ... WITH PASSWORD  aus.
#
# Liegt neben main.tf im selben Projekt → wird vom selben `tofu apply` erfasst.

# Wo Postgres aus Sicht der OpenBao-Pods erreichbar ist.
# k3d spiegelt den Docker-Host unter host.k3d.internal in den Cluster
# (extern verifiziert: k3d.io, host-aliases).
variable "postgres_host" {
  type    = string
  default = "host.k3d.internal:5432"
}

variable "postgres_db" {
  type    = string
  default = "appdb"
}

# Connection-User: darf sich verbinden und Passwörter ändern.
# Für den Workshop der Superuser aus der docker-compose; produktiv ein
# dedizierter Rotations-User mit den nötigen Rechten.
variable "postgres_conn_user" {
  type    = string
  default = "postgres"
}

variable "postgres_conn_password" {
  type      = string
  sensitive = true
  default   = "changeme"
}

# Der bestehende App-User, dessen Passwort rotiert werden soll.
variable "rotated_user" {
  type    = string
  default = "app_user"
}

# 1) Database-Secrets-Engine unter "database/"
resource "vault_mount" "database" {
  path        = "database"
  type        = "database"
  description = "PostgreSQL Secrets Engine (Static Roles)"
}

# 2) Verbindung zur Postgres-Instanz.
#    {{username}}/{{password}} füllt OpenBao aus den Feldern username/password.
resource "vault_database_secret_backend_connection" "postgres" {
  backend       = vault_mount.database.path
  name          = "postgres"
  allowed_roles = ["app-static"]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${var.postgres_host}/${var.postgres_db}?sslmode=disable"
    username       = var.postgres_conn_user
    password       = var.postgres_conn_password
  }
}

# 3) Static Role: rotiert das Passwort des bestehenden Users alle 24 h.
#    rotation_period ist in Sekunden -> 86400 = 24 h.
resource "vault_database_secret_backend_static_role" "app" {
  backend  = vault_mount.database.path
  name     = "app-static"
  db_name  = vault_database_secret_backend_connection.postgres.name
  username = var.rotated_user

  rotation_period     = 86400
  rotation_statements = ["ALTER USER \"{{name}}\" WITH PASSWORD '{{password}}';"]
}

# 4) Policy: aktuelles (rotiertes) Passwort der Static Role lesen.
#    Für den ESO-Token bzw. die App-Identität.
resource "vault_policy" "db_app_read" {
  name   = "db-app-read"
  policy = <<-EOT
    path "database/static-creds/app-static" {
      capabilities = ["read"]
    }
  EOT
}
