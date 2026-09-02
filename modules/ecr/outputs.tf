output "repository_urls" {
  description = "ECR repository URLs."

  value = {
    for name, repository in aws_ecr_repository.services :
    name => repository.repository_url
  }
}
