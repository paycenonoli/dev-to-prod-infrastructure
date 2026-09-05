Dev-to-Prod Promotion — Infrastructure

This repository contains the Infrastructure as Code (IaC) for the dev-to-prod-promotion project.

The goal is to build a realistic DevOps delivery path in which application code moves from development to staging and production using:

Terraform

Terragrunt

AWS

Amazon ECR

S3 remote Terraform state

IAM least-privilege access

The application and GitOps repositories are separate:

dev-to-prod-microservices-app
dev-to-prod-microservices-gitops
dev-to-prod-infrastructure   <-- this repository

1. Infrastructure Architecture

The current infrastructure foundation uses a shared Amazon ECR registry for the three microservices:

                    GitHub
                       |
                       v
             Infrastructure Repository
                       |
                       v
                  Terragrunt
                       |
                       v
                  Terraform
                       |
          +------------+------------+
          |                         |
          v                         v
     S3 Remote State             AWS ECR
          |                  +------+------+
          |                  |      |      |
          v                  v      v      v
   Terraform State       frontend  product  order
                         service   service  service

ECR repositories:

frontend
product-service
order-service

These repositories are shared infrastructure because the project uses one K3s cluster with separate Kubernetes namespaces for:

microservices-dev
microservices-staging
microservices-prod

The same application artifact can therefore be promoted from environment to environment rather than rebuilding different images for each environment.

2. Terraform vs Terragrunt

Terraform

Terraform is the Infrastructure as Code execution engine.

Terraform is responsible for:

defining AWS resources

creating resources

updating resources

destroying resources when explicitly required

generating execution plans

maintaining Terraform state

communicating with AWS through the AWS provider

For example, the ECR module defines:

resource "aws_ecr_repository" "services" {
  for_each = toset(var.repositories)

  name                 = each.value
  image_tag_mutability = var.image_tag_mutability

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

Terraform knows what resources should exist.

Terragrunt

Terragrunt is the orchestration/configuration layer around Terraform.

In this project Terragrunt is used for:

organizing environments and infrastructure units

supplying module inputs

sharing remote-state configuration

keeping Terraform configuration DRY

making it easier to manage multiple independent infrastructure units

A useful mental model:

Terraform  = construction crew
Terragrunt = construction manager

Terraform performs the actual infrastructure changes. Terragrunt coordinates how and where Terraform is used.

3. Repository Structure

Relevant infrastructure structure:

infrastructure/
├── README.md
├── bootstrap/
│   └── main.tf
├── environments/
│   ├── dev/
│   │   ├── terraform.tfvars
│   │   └── terragrunt.hcl
│   ├── production/
│   │   ├── terraform.tfvars
│   │   └── terragrunt.hcl
│   ├── shared/
│   │   └── ecr/
│   │       └── terragrunt.hcl
│   └── staging/
│       ├── terraform.tfvars
│       └── terragrunt.hcl
├── modules/
│   ├── ecr/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── variables.tf
│   ├── eks/
│   ├── iam/
│   └── vpc/
└── terragrunt.hcl

The shared/ecr unit manages resources that are shared by the application environments.

4. Terraform Remote State

The root Terragrunt configuration uses Amazon S3 for Terraform remote state.

Current configuration:

remote_state {
  backend = "s3"

  config = {
    bucket       = "dev-to-prod-promotion-terraform-state"
    key          = "${path_relative_to_include()}/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

Why remote state?

Terraform state contains information about infrastructure Terraform manages.

A local state file is problematic when infrastructure is managed by a team because:

state exists only on one machine

multiple engineers can work with different copies

state can be lost

collaboration becomes difficult

concurrent operations can cause problems

S3 gives us centralized state storage.

The state bucket is:

dev-to-prod-promotion-terraform-state

Region:

us-east-1

The project also uses S3-native state locking through:

use_lockfile = true

5. State Bucket Security

The Terraform state bucket was bootstrapped with:

S3 versioning enabled

server-side encryption using AES-256

public access blocked

The public access block uses:

block_public_acls       = true
block_public_policy     = true
ignore_public_acls      = true
restrict_public_buckets = true

Terraform state should be treated as sensitive infrastructure data.

6. Bootstrap Problem

There is a bootstrapping dependency:

Terraform needs S3
        |
        v
S3 stores Terraform state
        |
        v
But Terraform normally wants to use the S3 backend
before managing resources

Therefore the state bucket had to be created first.

A separate bootstrap configuration was used:

bootstrap/main.tf

The bootstrap Terraform configuration created:

S3 state bucket
S3 versioning
S3 encryption
S3 public access block

After the bucket existed, the normal Terragrunt/Terraform configuration could use the S3 remote backend.

This is a common IaC bootstrap pattern.

7. Bootstrap Incident: GetBucketTagging AccessDenied

During the initial bootstrap apply, Terraform successfully created the S3 bucket but then failed while trying to perform an S3 tagging-related operation.

The failure was caused by insufficient IAM permissions for the EC2 instance role.

The important lesson was:

Terraform can partially complete an apply before encountering a permission failure.

After the failure, Terraform reported the existing bucket in a tainted state and a subsequent plan showed a potentially dangerous:

-/+ destroy/recreate

plan.

What we did NOT do

We did not blindly approve the destroy/recreate plan.

Destroying and recreating an infrastructure resource simply because Terraform reports it as tainted can be dangerous.

Recovery

We removed the taint:

terraform untaint aws_s3_bucket.terraform_state

Then we ran another plan.

The corrected plan showed:

3 to add, 1 to change, 0 to destroy

The apply then completed successfully:

Apply complete! Resources: 3 added, 1 changed, 0 destroyed.

Lesson

Always inspect:

terraform plan

before applying.

Pay particular attention to:

-/+ destroy/recreate

and:

- destroy

operations.

A successful-looking Terraform command is not enough; the plan must be reviewed.

8. IAM and Least Privilege

The EC2 instance uses an IAM role rather than storing long-lived AWS access keys on the server.

The role used by the instance is:

dev-to-prod-promo-ec2-role

AWS identity verification:

aws sts get-caller-identity

The project deliberately uses IAM permissions required for the infrastructure instead of giving the instance unrestricted AWS administrator access.

9. ECR IAM Incident

Initially, the EC2 role had:

AmazonEC2ContainerRegistryPowerUser

attached.

However, the actual policy did not contain:

ecr:CreateRepository

This produced:

AccessDeniedException

when Terraform attempted to create the ECR repositories.

We reproduced the problem outside Terraform with:

aws ecr create-repository \
  --repository-name iam-permission-test \
  --region us-east-1

The same AccessDeniedException occurred.

This was important because it proved that the problem was AWS IAM authorization, not Terraform or Terragrunt.

10. Least-Privilege ECR Permission

A targeted inline IAM policy was added for ECR repository management.

The relevant permissions included:

{
  "Effect": "Allow",
  "Action": [
    "ecr:CreateRepository",
    "ecr:DeleteRepository",
    "ecr:TagResource"
  ],
  "Resource": "*"
}

ecr:CreateRepository was the permission required to unblock repository creation.

ecr:DeleteRepository was added because Terraform may need to destroy repositories that it manages.

ecr:TagResource is required when repository tags are supplied during creation.

We deliberately did not grant:

ecr:*

or:

AdministratorAccess

for this task.

This demonstrates a least-privilege approach.

11. Why We Tested IAM Directly

The troubleshooting sequence was:

Terragrunt apply
       |
       v
AccessDenied: ecr:CreateRepository
       |
       v
Test the same AWS API directly
       |
       v
aws ecr create-repository ...
       |
       v
AccessDenied
       |
       v
Inspect IAM policy
       |
       v
Missing permission identified
       |
       v
Add targeted permission
       |
       v
Repeat direct AWS CLI test
       |
       v
SUCCESS
       |
       v
Return to Terraform

This is a useful production troubleshooting pattern:

Reduce a higher-level tool failure to the underlying API call and test that API directly.

12. ECR Infrastructure

The ECR Terraform module creates repositories using:

repositories = [
  "frontend",
  "product-service",
  "order-service"
]

The repositories are configured with:

Image tag mutability: IMMUTABLE
Scan on push:         true
Encryption:           AES256

Terraform uses:

for_each = toset(var.repositories)

to create one ECR repository for each service.

13. Why ECR Tags Are Immutable

The repositories use:

IMMUTABLE

image tags.

This prevents an existing tag from being silently overwritten with different image content.

For example:

frontend:1.0.0

should represent one immutable application artifact.

A later build should use another version:

frontend:1.0.1

rather than replacing the contents of:

frontend:1.0.0

This supports a safer promotion model:

Build once
    |
    v
frontend:1.0.0
    |
    +--------> DEV
    |
    +--------> STAGING
    |
    +--------> PROD

The same artifact can move through environments.

14. ECR Security Settings

All three repositories were independently verified in AWS.

Expected configuration:

frontend
    IMMUTABLE
    Scan on push = true
    AES256

product-service
    IMMUTABLE
    Scan on push = true
    AES256

order-service
    IMMUTABLE
    Scan on push = true
    AES256

Verification command:

aws ecr describe-repositories \
  --region us-east-1 \
  --query 'repositories[].{Name:repositoryName,Mutability:imageTagMutability,Scan:imageScanningConfiguration.scanOnPush,Encryption:encryptionConfiguration.encryptionType}' \
  --output table

The AWS-side verification confirmed:

Encryption   Mutability   Name              Scan
AES256       IMMUTABLE    product-service    True
AES256       IMMUTABLE    order-service      True
AES256       IMMUTABLE    frontend           True

15. Terraform State Verification

AWS was also compared against Terraform state.

Command:

terragrunt state list

Expected resources:

aws_ecr_repository.services["frontend"]
aws_ecr_repository.services["order-service"]
aws_ecr_repository.services["product-service"]

This gives us two independent checks:

AWS CLI
   |
   +--> What actually exists in AWS?

Terraform state
   |
   +--> What does Terraform believe it manages?

Both matched after the ECR deployment.

16. ECR Outputs

Terraform exposes the repository URLs:

417521971848.dkr.ecr.us-east-1.amazonaws.com/frontend

417521971848.dkr.ecr.us-east-1.amazonaws.com/product-service

417521971848.dkr.ecr.us-east-1.amazonaws.com/order-service

These URLs will later be used by the application delivery pipeline.

The future flow will be:

Developer
   |
   v
GitHub
   |
   v
Jenkins
   |
   +--> Tests
   +--> SonarQube
   +--> Docker build
   +--> Security scan
   |
   v
Amazon ECR
   |
   +--> frontend
   +--> product-service
   +--> order-service

17. Manual ECR Authentication

For manual testing, Docker can authenticate to ECR using the EC2 instance role:

aws ecr get-login-password --region us-east-1 | \
docker login \
  --username AWS \
  --password-stdin \
  417521971848.dkr.ecr.us-east-1.amazonaws.com

This avoids storing long-lived AWS credentials on the EC2 instance.

The same concept will later be automated by Jenkins.

18. Infrastructure Workflow

The intended infrastructure workflow is:

Developer
    |
    v
Feature branch
    |
    v
Pull Request
    |
    v
Review
    |
    v
Merge to main
    |
    v
Terragrunt
    |
    v
Terraform
    |
    v
AWS

We should avoid making infrastructure changes directly on main without review.

19. Useful Commands

Check AWS identity

aws sts get-caller-identity

Initialize Terragrunt

terragrunt init

Generate a plan

terragrunt plan

Apply infrastructure

terragrunt apply

List Terraform-managed resources

terragrunt state list

Show Terraform outputs

terragrunt output

Inspect ECR repositories

aws ecr describe-repositories --region us-east-1

Inspect ECR images

aws ecr describe-images \
  --repository-name frontend \
  --region us-east-1

Verify Terraform state

terragrunt state list

Remove an incorrect Terraform taint

terraform untaint <resource-address>

Always run another plan after correcting a tainted resource.

20. What Went Wrong / Lessons Learned

This section intentionally documents failures instead of hiding them.

Incident 1 — S3 bootstrap IAM permissions

Symptom

Terraform created the S3 bucket but then failed during a tagging operation.

Cause

The EC2 IAM role did not initially have all S3 permissions required by the bootstrap configuration.

Recovery

IAM permissions were corrected, the tainted bucket resource was untainted, and Terraform was replanned.

Lesson

Do not blindly apply a plan containing an unexpected resource replacement.

Incident 2 — ECR repository creation denied

Symptom

Terragrunt/Terraform failed with:

AccessDeniedException
ecr:CreateRepository

Cause

The attached AWS managed ECR policy did not contain the required repository creation permission.

Recovery

The AWS CLI was used to reproduce the API call directly. A targeted IAM permission was added and the API test succeeded.

Lesson

When Terraform reports an AWS authorization error:

Identify the exact AWS API action.

Test that API action directly.

Inspect the effective IAM permissions.

Add the minimum required permission.

Retry Terraform.

Incident 3 — Temporary IAM test repository

A temporary repository was created to verify the new permission:

iam-permission-test

It was intentionally created outside Terraform so that the IAM permission could be tested independently.

Because it is not part of Terraform state, it must not be confused with the three Terraform-managed repositories.

Clean up temporary test resources after the test is complete.

21. Current Infrastructure Status

At the completion of the ECR phase:

S3 Terraform state       COMPLETE
S3 encryption            COMPLETE
S3 versioning            COMPLETE
S3 public access block   COMPLETE
Terragrunt remote state  COMPLETE
ECR repositories         COMPLETE
ECR immutable tags       COMPLETE
ECR scan-on-push         COMPLETE
ECR AES-256 encryption   COMPLETE
Terraform state          VERIFIED

ECR repositories:

frontend
product-service
order-service

22. Next Phase — Application Delivery

The next phase moves from infrastructure provisioning to application delivery.

The application repository contains three microservices:

frontend
product-service
order-service

The next delivery flow is:

Application Source
       |
       v
GitHub
       |
       v
Jenkins
       |
       +--> Unit Tests
       |
       +--> SonarQube
       |
       +--> Docker Build
       |
       +--> Trivy Security Scan
       |
       v
Amazon ECR
       |
       v
K3s
       |
       +--> microservices-dev
       |
       +--> microservices-staging
       |
       +--> microservices-prod

The eventual goal is:

Build the application image once, store the immutable artifact in ECR, and promote that same artifact through Dev → Staging → Production.

This infrastructure repository provides the AWS foundation for that workflow.
