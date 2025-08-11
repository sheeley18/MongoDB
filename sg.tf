# Security Group for EC2 instance
resource "aws_security_group" "terraform_sg" { 
  name        = "allow_ssh_mongo"
  description = "Security group to allow SSH and MongoDB access"
  vpc_id      = aws_vpc.mongo_vpc.id   
  
  tags = {
    Name = "Terraform_project_sg"
  }
}

# SSH access rule
resource "aws_vpc_security_group_ingress_rule" "allow_ssh_ipv4" {  
  security_group_id = aws_security_group.terraform_sg.id  
  cidr_ipv4         = "73.234.1.227/32"  # Your IP only, not 0.0.0.0/0
  from_port         = 22
  ip_protocol       = "tcp"
  to_port           = 22
  
  tags = {
    Name = "SSH_Access_MyIP"
  }
}

# MongoDB access rule - SECURED: Only allow access from your IP
resource "aws_vpc_security_group_ingress_rule" "allow_mongo_my_ip" {
  security_group_id = aws_security_group.terraform_sg.id
  cidr_ipv4         = "73.234.1.227/32"  # Your home network IP
  from_port         = 27017
  ip_protocol       = "tcp"
  to_port           = 27017
  
  tags = {
    Name = "MongoDB_Access_MyIP"
  }
}

# OPTIONAL: MongoDB access from within VPC (keep for internal access)
resource "aws_vpc_security_group_ingress_rule" "allow_mongo_vpc" {
  security_group_id = aws_security_group.terraform_sg.id
  cidr_ipv4         = "192.168.0.0/16"  # VPC CIDR block
  from_port         = 27017
  ip_protocol       = "tcp"
  to_port           = 27017
  
  tags = {
    Name = "MongoDB_VPC_Access"
  }
}

# Egress rule - allow all outbound traffic
resource "aws_vpc_security_group_egress_rule" "allow_all_traffic_ipv4" {
  security_group_id = aws_security_group.terraform_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"  # All protocols and ports
  
  tags = {
    Name = "All_Outbound"
  }
}

# Output security group ID for use in other modules
output "security_group_id" {
  description = "ID of the security group"
  value       = aws_security_group.terraform_sg.id
}

