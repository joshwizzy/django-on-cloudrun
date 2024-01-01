terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.9.0"
    }

    random = {
      version = "~> 3.6.0"
    }
  }
}

# Store Terraform state in a Google Cloud Storage bucket
terraform {
  backend "gcs" {
    bucket = "PROJECT_ID-tfstate"
  }
}

provider "google" {
  project = var.project
}

# Enable the required Google Cloud APIs
resource "google_project_service" "all" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "compute.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "sql-component.googleapis.com",
    "sqladmin.googleapis.com",
  ])
  project            = var.project
  service            = each.key
  disable_on_destroy = false
}

# Create a service account for the Cloud Run service
resource "google_service_account" "django_cloudrun" {
  account_id = "django-run-sa"
  project    = var.project
}

# Create a Artifact Repository to store the application image
resource "google_artifact_registry_repository" "main" {
  format        = "DOCKER"
  location      = var.region
  project       = var.project
  repository_id = "django-app"

  depends_on = [
    google_project_service.all
  ]
}

# Provision a database server instance for the application
resource "google_sql_database_instance" "main" {
  name             = "django"
  database_version = "POSTGRES_14"
  region           = var.region
  settings {
    tier = "db-f1-micro"
  }
  deletion_protection = true

  depends_on = [
    google_project_service.all
  ]
}

# Create a database within the instance 
resource "google_sql_database" "main" {
  name     = "django"
  instance = google_sql_database_instance.main.name
}

# Create a random password for the app database user
resource "random_password" "db_password" {
  length  = 32
  special = false
}

# Create the Django application database user
resource "google_sql_user" "django" {
  name     = "django"
  instance = google_sql_database_instance.main.name
  password = random_password.db_password.result
}

# Define local variables
locals {
  service_account = "serviceAccount:${google_service_account.django_cloudrun.email}"
  repository_id   = google_artifact_registry_repository.main.repository_id
  ar_repository   = "${var.region}-docker.pkg.dev/${var.project}/${local.repository_id}"
  image           = "${local.ar_repository}/${var.service_name}:bootstrap"
}

# Assign the Cloud Run service the required roles to connect to the DB and fetch service metadata
resource "google_project_iam_member" "service_roles" {
  for_each = toset([
    "cloudsql.client",
    "run.viewer",
  ])
  project = var.project
  role    = "roles/${each.key}"
  member  = local.service_account
}

# Create a Cloud Storage bucket to store static files
resource "google_storage_bucket" "staticfiles" {
  name     = "${var.project}-staticfiles"
  location = "US"
}

# Grant the Cloud Run service account admin access to the staticfiles bucket
resource "google_storage_bucket_iam_binding" "staticfiles_bucket" {
  bucket = google_storage_bucket.staticfiles.name
  role   = "roles/storage.admin"
  members = [
    local.service_account
  ]
}

# Create a random string to use as the Django secret key
resource "random_password" "django_secret_key" {
  special = false
  length  = 50
}

resource "google_secret_manager_secret" "application_settings" {
  secret_id = "application_settings"

  replication {
    auto {}
  }
  depends_on = [google_project_service.all]

}

# Replace the Terraform template variables and save the rendered content as a secret
resource "google_secret_manager_secret_version" "application_settings" {
  secret = google_secret_manager_secret.application_settings.id

  secret_data = templatefile("${path.module}/templates/application_settings.tftpl", {
    staticfiles_bucket = google_storage_bucket.staticfiles.name
    # media_bucket       = google_storage_bucket.media.name
    secret_key = random_password.django_secret_key.result
    user       = google_sql_user.django
    instance   = google_sql_database_instance.main
    database   = google_sql_database.main
  })
}

# Grant the Cloud Run service account access to the application settings secret
resource "google_secret_manager_secret_iam_binding" "application_settings" {
  secret_id = google_secret_manager_secret.application_settings.id
  role      = "roles/secretmanager.secretAccessor"
  members   = [local.service_account]
}

# Generate a random password for the superuser
resource "random_password" "superuser_password" {
  length  = 32
  special = false
}

# Save the superuser password as a secret
resource "google_secret_manager_secret" "superuser_password" {
  secret_id = "superuser_password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.all]
}

resource "google_secret_manager_secret_version" "superuser_password" {
  secret      = google_secret_manager_secret.superuser_password.id
  secret_data = random_password.superuser_password.result
}

# Grant the Cloud Run service account access to the superuser password secret
resource "google_secret_manager_secret_iam_binding" "superuser_password" {
  secret_id = google_secret_manager_secret.superuser_password.id
  role      = "roles/secretmanager.secretAccessor"
  members   = [local.service_account]
}

# Build the application image that the Cloud Run service and jobs will use
resource "terraform_data" "bootstrap" {
  provisioner "local-exec" {
    working_dir = "${path.module}/../djangocloudrun"
    command     = "gcloud builds submit --pack image=${local.image} ."
  }

  depends_on = [
    google_artifact_registry_repository.main,
    google_project_service.all
  ]
}

# Create the migrate_collectstatic Cloud Run job
resource "google_cloud_run_v2_job" "migrate_collectstatic" {
  name     = "migrate-collectstatic"
  location = var.region

  template {
    template {
      service_account = google_service_account.django_cloudrun.email

      volumes {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [google_sql_database_instance.main.connection_name]
        }
      }

      containers {
        image   = local.image
        command = ["migrate_collectstatic"]

        env {
          name = "APPLICATION_SETTINGS"
          value_source {
            secret_key_ref {
              version = google_secret_manager_secret_version.application_settings.version
              secret  = google_secret_manager_secret_version.application_settings.secret
            }
          }
        }

        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }

      }
    }
  }

  depends_on = [
    terraform_data.bootstrap,
  ]
}

# Create the create_superuser Cloud Run job
resource "google_cloud_run_v2_job" "create_superuser" {
  name     = "create-superuser"
  location = var.region

  template {
    template {
      service_account = google_service_account.django_cloudrun.email

      volumes {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [google_sql_database_instance.main.connection_name]
        }
      }

      containers {
        image   = local.image
        command = ["create_superuser"]

        env {
          name = "APPLICATION_SETTINGS"
          value_source {
            secret_key_ref {
              version = google_secret_manager_secret_version.application_settings.version
              secret  = google_secret_manager_secret_version.application_settings.secret
            }
          }
        }

        env {
          name = "DJANGO_SUPERUSER_PASSWORD"
          value_source {
            secret_key_ref {
              version = google_secret_manager_secret_version.superuser_password.version
              secret  = google_secret_manager_secret_version.superuser_password.secret
            }
          }
        }

        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }

      }
    }
  }

  depends_on = [
    terraform_data.bootstrap
  ]
}

# Run the migrate_collectstatic the Cloud Run job
resource "terraform_data" "execute_migrate_collectstatic" {
  provisioner "local-exec" {
    command = "gcloud run jobs execute migrate-collectstatic --region ${var.region} --wait"
  }

  depends_on = [
    google_cloud_run_v2_job.migrate_collectstatic,
  ]
}

# Run the create_superuser the Cloud Run job
resource "terraform_data" "execute_create_superuser" {

  provisioner "local-exec" {
    command = "gcloud run jobs execute create-superuser --region ${var.region} --wait"
  }

  depends_on = [
    google_cloud_run_v2_job.create_superuser,
  ]
}

# Create and deploy the Cloud Run service
resource "google_cloud_run_service" "app" {
  name                       = var.service_name
  location                   = var.region
  autogenerate_revision_name = true

  lifecycle {
    replace_triggered_by = [terraform_data.bootstrap]
  }

  template {
    spec {
      service_account_name = google_service_account.django_cloudrun.email
      containers {
        image = local.image

        env {
          name  = "SERVICE_NAME"
          value = var.service_name
        }

        env {
          name = "APPLICATION_SETTINGS"
          value_from {
            secret_key_ref {
              key  = google_secret_manager_secret_version.application_settings.version
              name = google_secret_manager_secret.application_settings.secret_id
            }
          }
        }
      }
    }

    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale"      = "1"
        "run.googleapis.com/cloudsql-instances" = google_sql_database_instance.main.connection_name
        "run.googleapis.com/client-name"        = "terraform"
      }
    }


  }

  traffic {
    percent         = 100
    latest_revision = true
  }

  depends_on = [
    terraform_data.execute_migrate_collectstatic,
    terraform_data.execute_create_superuser,
  ]

}

# Grant permission to unauthenticated users to invoke the Cloud Run service
data "google_iam_policy" "noauth" {
  binding {
    role    = "roles/run.invoker"
    members = ["allUsers"]
  }
}

resource "google_cloud_run_service_iam_policy" "noauth" {
  location = google_cloud_run_service.app.location
  project  = google_cloud_run_service.app.project
  service  = google_cloud_run_service.app.name

  policy_data = data.google_iam_policy.noauth.policy_data
}

# Print the Cloud Run service url
output "service_url" {
  value = google_cloud_run_service.app.status[0].url
}
