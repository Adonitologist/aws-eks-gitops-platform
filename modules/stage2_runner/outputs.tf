output "instance_id" {
  value       = aws_instance.runner.id
  description = "ID of the stage 2 runner instance (start it before use and stop it when idle)"
}

output "role_arn" {
  value       = aws_iam_role.runner.arn
  description = "ARN of the IAM role of the runner (holds the EKS access entry)"
}

output "security_group_id" {
  value       = aws_security_group.runner.id
  description = "ID of the runner security group (source of the ingress rule on the cluster security group)"
}

output "session_log_group_name" {
  value       = aws_cloudwatch_log_group.sessions.name
  description = "Name of the CloudWatch log group that receives the Session Manager session logs"
}

output "session_document_name" {
  value       = aws_ssm_document.session_preferences.name
  description = "Name of the Session document of the runner (logging and idle timeout apply only to sessions started with it)"
}

output "ssm_session_command" {
  value       = "aws ssm start-session --target ${aws_instance.runner.id} --document-name ${aws_ssm_document.session_preferences.name}"
  description = "Command to open a logged shell on the runner (requires the Session Manager plugin and a started instance)"
}

output "operator_policy_example_json" {
  value       = data.aws_iam_policy_document.operator_example.json
  description = "EXAMPLE ONLY, not created or attached by Terraform: IAM policy for the operator identity that limits Session Manager to the runner and its session document"
}
