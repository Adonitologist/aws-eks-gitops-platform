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

output "ssm_session_command" {
  value       = "aws ssm start-session --target ${aws_instance.runner.id}"
  description = "Command to open a shell on the runner (requires the Session Manager plugin and a started instance)"
}
