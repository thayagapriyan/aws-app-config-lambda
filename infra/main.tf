terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Partial: the bucket is per account, so CI passes
  #   -backend-config=bucket=<account-id>-tf-remote-state
  # The key must start with "aws-app-config-lambda/" - the only prefix the vended deploy
  # role may write (aws-foundation/role-vending/repos/aws-app-config-lambda.yaml).
  backend "s3" {
    key          = "aws-app-config-lambda/main.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { Repo = "aws-app-config-lambda", Environment = var.env }
  }
}

variable "env" {
  description = "dev | prod. Picks config/<env>.json; dev and prod are separate accounts."
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "env must be dev or prod."
  }
}

locals {
  # Every IAM role here must start with this: the deploy role may only manage its prefix.
  name    = "aws-app-config-lambda"
  app_dir = "${path.module}/../apps/config-lambda"
}

# --- AppConfig ------------------------------------------------------------------

resource "aws_appconfig_application" "this" {
  name = local.name
}

resource "aws_appconfig_environment" "this" {
  name           = var.env
  application_id = aws_appconfig_application.this.id
}

resource "aws_appconfig_configuration_profile" "settings" {
  name           = "settings"
  application_id = aws_appconfig_application.this.id
  location_uri   = "hosted"
  type           = "AWS.Freeform"
}

resource "aws_appconfig_hosted_configuration_version" "settings" {
  application_id           = aws_appconfig_application.this.id
  configuration_profile_id = aws_appconfig_configuration_profile.settings.configuration_profile_id
  content_type             = "application/json"
  content                  = file("${local.app_dir}/config/${var.env}.json")

  # Only a change to config/<env>.json creates a new version (1, 2, 3, ...); otherwise
  # the current one stays. A new version is created and deployed before the old one is
  # deleted - git history of the JSON file is the record of old versions.
  lifecycle {
    create_before_destroy = true
  }
}

# AppConfig.AllAtOnce still bakes for 10 minutes, and an environment takes one
# deployment at a time, so two quick merges would collide. This one completes at once.
resource "aws_appconfig_deployment_strategy" "instant" {
  name                           = "${local.name}-instant"
  deployment_duration_in_minutes = 0
  final_bake_time_in_minutes     = 0
  growth_factor                  = 100
  replicate_to                   = "NONE"
}

resource "aws_appconfig_deployment" "settings" {
  application_id           = aws_appconfig_application.this.id
  environment_id           = aws_appconfig_environment.this.environment_id
  configuration_profile_id = aws_appconfig_configuration_profile.settings.configuration_profile_id
  configuration_version    = aws_appconfig_hosted_configuration_version.settings.version_number
  deployment_strategy_id   = aws_appconfig_deployment_strategy.instant.id
}

# --- Lambda ---------------------------------------------------------------------

# AWS publishes the current extension layer here, so there is no version to bump.
# A new layer shows up as a Lambda update in plan.
data "aws_ssm_parameter" "appconfig_extension" {
  name = "/aws/service/aws-appconfig/lambda-extension/arm64/latest"
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${local.app_dir}/dist/index.mjs"
  output_path = "${path.module}/.build/lambda.zip"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-fn"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "read_config" {
  statement {
    actions = ["appconfig:StartConfigurationSession", "appconfig:GetLatestConfiguration"]
    resources = [
      "${aws_appconfig_application.this.arn}/environment/${aws_appconfig_environment.this.environment_id}/configuration/${aws_appconfig_configuration_profile.settings.configuration_profile_id}",
    ]
  }
}

resource "aws_iam_role_policy" "read_config" {
  name   = "read-config"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.read_config.json
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 14
}

# publish = true: a code or config change publishes a new Lambda version. The config
# version is in its env vars, and depends_on means that version is already deployed
# (so the extension serves it) before the Lambda version is published.
resource "aws_lambda_function" "this" {
  function_name    = local.name
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs24.x"
  architectures    = ["arm64"]
  handler          = "index.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  layers           = [data.aws_ssm_parameter.appconfig_extension.insecure_value]
  publish          = true

  # Read by src/config.ts (AppConfigExtension); APPCONFIG_VERSION by src/handler.ts.
  environment {
    variables = {
      APPCONFIG_APPLICATION = aws_appconfig_application.this.name
      APPCONFIG_ENVIRONMENT = aws_appconfig_environment.this.name
      APPCONFIG_PROFILE     = aws_appconfig_configuration_profile.settings.name
      APPCONFIG_VERSION     = aws_appconfig_hosted_configuration_version.settings.version_number
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_appconfig_deployment.settings]
}

# Follows the newest published version for now. Holding it back (promotion) is one of
# the deploy cases still to decide; an ALB would target this alias.
resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.this.function_name
  function_version = aws_lambda_function.this.version
}

# Public by choice: the config holds nothing sensitive. With NONE, Lambda adds the
# InvokeFunctionUrl/InvokeFunction permissions itself; no aws_lambda_permission needed.
resource "aws_lambda_function_url" "this" {
  function_name      = aws_lambda_function.this.function_name
  qualifier          = aws_lambda_alias.live.name
  authorization_type = "NONE"
}

output "function_url" {
  value = aws_lambda_function_url.this.function_url
}
