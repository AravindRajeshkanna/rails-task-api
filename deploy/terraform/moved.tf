# Resources that gained a `count` for the multi-region pair (a standby does not create them) changed address from `x` to `x[0]`.
# Without these, a stack applied from an earlier commit would plan to DESTROY and recreate them: new random passwords, a new
# signing key (every issued token invalid), new IAM roles. With them the move is recorded and nothing is replaced. They are
# harmless in a stack that never had the old addresses.

moved {
  from = random_password.api_database
  to   = random_password.api_database[0]
}

moved {
  from = random_password.auth_database
  to   = random_password.auth_database[0]
}

moved {
  from = random_password.notifications_database
  to   = random_password.notifications_database[0]
}

moved {
  from = random_password.metrics_token
  to   = random_password.metrics_token[0]
}

moved {
  from = random_password.ai_service_token
  to   = random_password.ai_service_token[0]
}

moved {
  from = tls_private_key.auth_jwt
  to   = tls_private_key.auth_jwt[0]
}

moved {
  from = aws_secretsmanager_secret.ai_service_token
  to   = aws_secretsmanager_secret.ai_service_token[0]
}

moved {
  from = aws_secretsmanager_secret_version.ai_service_token
  to   = aws_secretsmanager_secret_version.ai_service_token[0]
}

moved {
  from = aws_iam_user.ses_smtp
  to   = aws_iam_user.ses_smtp[0]
}

moved {
  from = aws_iam_user_policy.ses_smtp
  to   = aws_iam_user_policy.ses_smtp[0]
}

moved {
  from = aws_iam_access_key.ses_smtp
  to   = aws_iam_access_key.ses_smtp[0]
}

moved {
  from = aws_iam_role.github_deploy
  to   = aws_iam_role.github_deploy[0]
}

moved {
  from = aws_iam_role_policy.github_deploy
  to   = aws_iam_role_policy.github_deploy[0]
}
