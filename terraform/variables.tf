variable "env" {
  type        = string
  description = "The Environment type where the resources will be deployed"
}

variable "region" {
  type        = string
  description = "AWS Region where the provider will operate"
  default     = "us-east-1"
}

variable "cidr" {
  type        = string
  description = "The IPv4 CIDR block for the VPC"
  validation {
    condition     = can(cidrsubnet(var.cidr, 8, 1))
    error_message = "Please enter valid Cidr Block"
  }
}

variable "bastion_instance_type" {
  type        = string
  description = "Size to use for the bastion host instance"
  default     = "t2.micro"
}

variable "public_key" {
  type        = string
  description = "The path to file which contain public key material"
  default     = "~/.ssh/id_rsa.pub"
}

variable "my_public_ip" {
  type        = string
  description = "The ip that is allowed to SSH into bastion host"
  sensitive   = true
}

variable "frontend_instance_type" {
  type        = string
  description = "Size to use for the frontend template"
  default     = "t2.micro"
}

variable "backend_instance_type" {
  type        = string
  description = "Size to use for the backend template"
  default     = "t2.micro"
}

variable "frontend_script" {
  type        = string
  description = "Script that will run on frontend instances"
  default     = "./frontend.sh"
}

variable "backend_script" {
  type        = string
  description = "Script that will run on backend instances"
  default     = "./backend.sh"
}

variable "db_instance_type" {
  type        = string
  description = "Size to use for the database instances"
  default     = "db.t3.micro"
}

variable "db_username" {
  type        = string
  description = "The username of data pase"
  sensitive   = true
}

variable "db_password" {
  type        = string
  description = "The password of database"
  sensitive   = true
}

variable "sns_email" {
  type        = string
  description = "Email address to recieve emails from sns"
}

variable "domain_name" {
  type        = string
  description = " The name of the hosted zone"
}

variable "logs_bucket_name" {
  type        = string
  description = "Name of the bucket"
}