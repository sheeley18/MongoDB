# Regional Configuration
variable "REGION" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "ZONE1" {
  description = "First availability zone"
  type        = string
  default     = "us-east-1a"
}

variable "ZONE2" {
  description = "Second availability zone"
  type        = string
  default     = "us-east-1b"
}

variable "ZONE3" {
  description = "Third availability zone"
  type        = string
  default     = "us-east-1c"
}

# AMI Configuration
variable "AMIS" {
  description = "AMI IDs for different regions"
  type        = map(string)
  default = {
    us-east-1 = "ami-0fc5d935ebf8bc3bc"  # Ubuntu 22.04 LTS
    us-west-1 = "ami-0d382e80be7ffdae5"  # Ubuntu 22.04 LTS
    us-west-2 = "ami-03f65b8614a860c29"  # Ubuntu 22.04 LTS
    eu-west-1 = "ami-0905a3c97561e0b69"  # Ubuntu 22.04 LTS
  }
  
  validation {
    condition = length(var.AMIS) > 0
    error_message = "At least one AMI must be specified."
  }
}

# User configuration
variable "USER" {
  description = "Default user for the AMI"
  type        = string  
  default     = "ubuntu"
  
  validation {
    condition     = length(var.USER) > 0
    error_message = "User cannot be empty."
  }
}

# Key pair configuration
variable "PUBLIC_KEY" {
  description = "Name of the existing AWS key pair to use for SSH"
  type        = string
  default     = "TASKY"
  
  validation {
    condition     = length(var.PUBLIC_KEY) > 0
    error_message = "Public key name cannot be empty."
  }
}

# Instance configuration
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
  
  validation {
    condition = contains([
      "t2.micro", "t2.small", "t2.medium", "t2.large",
      "t3.micro", "t3.small", "t3.medium", "t3.large"
    ], var.instance_type)
    error_message = "Instance type must be a valid t2 or t3 instance type."
  }
}