terraform {
  backend "s3" {
    bucket         = "yonatan-bucket"
    key            = "eks/terraform.tfstate"           
    region         = "us-west-2"
    encrypt        = true
    dynamodb_table = "yonatan-terraform-state-lock"
  }
}