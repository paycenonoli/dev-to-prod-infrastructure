variable "repositories" {
  description = "Names of the ECR repositories to create."
  type        = list(string)
}

variable "image_tag_mutability" {
  description = "Whether ECR image tags can be overwritten."
  type        = string
  default     = "IMMUTABLE"
}

variable "scan_on_push" {
  description = "Enable vulnerability scanning when images are pushed."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags applied to ECR repositories."
  type        = map(string)
  default     = {}
}
