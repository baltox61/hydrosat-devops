resource "kubernetes_namespace" "dagster" {
  metadata { name = var.dagster_namespace }
}

resource "kubernetes_secret" "openweather" {
  metadata {
    name      = "openweather-api"
    namespace = var.dagster_namespace
  }
  data = {
    OPENWEATHER_API_KEY = base64encode(var.openweather_api_key)
  }
  type = "Opaque"
}

resource "helm_release" "dagster" {
  name       = "dagster"
  repository = "https://dagster-io.github.io/helm"
  chart      = "dagster"
  namespace  = var.dagster_namespace
  version    = "1.11.13"
  wait       = true

  values = [yamlencode({
    dagsterWebserver = {
      service = { type = "LoadBalancer" }
      env = [
        { name = "WEATHER_RESULTS_BUCKET", value = var.products_bucket }
      ]
    }
    postgresql = {
      enabled = True
      auth = { username = "dagster", password = "dagsterpass", database = "dagster" }
      primary = { persistence = { enabled = True, size = "20Gi" } }
    }
    userDeployments = {
      enabled = True
      deployments = [{
        name = "user-code"
        image = {
          repository = "public.ecr.aws/docker/library/python"
          tag        = "3.11-slim"
          pullPolicy = "IfNotPresent"
        }
        env = [
          { name = "OPENWEATHER_API_KEY", valueFrom = { secretKeyRef = { name = "openweather-api", key = "OPENWEATHER_API_KEY" } } },
          { name = "WEATHER_RESULTS_BUCKET", value = var.products_bucket }
        ]
        serviceAccount = {
          create = true
          name   = "dagster-user-code"
          annotations = {
            "eks.amazonaws.com/role-arn" = module.iam_role_dagster.iam_role_arn
          }
        }
        codeServer = {
          runAsUser = 1000
          k8s = {
            containerConfig = {
              env = [
                { name = "PYTHONPATH", value = "/opt/dagster/app" }
              ]
              volumeMounts = [{ name = "repo", mountPath = "/opt/dagster/app" }]
            }
            volumes = [{ name = "repo", configMap = { name = "dagster-repo" } }]
          }
        }
      }]
      enableSubcharts = true
    }
    extraManifests = [
      {
        apiVersion = "v1"
        kind       = "ConfigMap"
        metadata = {
          name      = "dagster-repo"
          namespace = var.dagster_namespace
        }
        data = {
          "weather_pipeline.py" = file("${path.module}/../dagster_jobs/weather_pipeline.py")
          "__init__.py"         = file("${path.module}/../dagster_jobs/__init__.py")
        }
      }
    ]
  })]
}
