# Security Group for MongoDB EC2 instance
resource "aws_security_group" "mongodb_sg" { 
  name        = "mongodb_secure_sg"
  description = "Security group for MongoDB - SSH and VPC access only"
  vpc_id      = aws_vpc.mongo_vpc.id   
  
  tags = {
    Name = "MongoDB_Secure_SG"
  }
}


resource "aws_vpc_security_group_ingress_rule" "allow_ssh_admin" {  
  security_group_id = aws_security_group.mongodb_sg.id  
  cidr_ipv4         = var.admin_ip
  from_port         = 22
  ip_protocol       = "tcp"
  to_port           = 22
  
  tags = {
    Name = "SSH_Access_Admin"
  }
}

# MongoDB access from VPC - will be used by EKS
resource "aws_vpc_security_group_ingress_rule" "allow_mongo_vpc" {
  security_group_id = aws_security_group.mongodb_sg.id
  cidr_ipv4         = "192.168.0.0/16"  # VPC CIDR block
  from_port         = 27017
  ip_protocol       = "tcp"
  to_port           = 27017
  
  tags = {
    Name = "MongoDB_VPC_Access"
  }
}

# Egress rule - allow all outbound traffic
resource "aws_vpc_security_group_egress_rule" "allow_all_outbound" {
  security_group_id = aws_security_group.mongodb_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  
  tags = {
    Name = "All_Outbound"
  }
}


output "security_group_id" {
  description = "ID of the MongoDB security group"
  value       = aws_security_group.mongodb_sg.id
}
