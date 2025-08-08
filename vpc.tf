# Main VPC
resource "aws_vpc" "mongo_vpc" {  
  cidr_block           = "192.168.0.0/16"
  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true
  
  tags = {
    Name = "mongo_vpc"  
  }
}

# Public Subnets
resource "aws_subnet" "public_subnet_1" {
  vpc_id                  = aws_vpc.mongo_vpc.id  
  cidr_block              = "192.168.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = var.ZONE1
  
  tags = {
    Name = "Public_Subnet_1"
  }
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id                  = aws_vpc.mongo_vpc.id  
  cidr_block              = "192.168.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = var.ZONE2
  
  tags = {
    Name = "Public_Subnet_2"
  }
}

resource "aws_subnet" "public_subnet_3" {
  vpc_id                  = aws_vpc.mongo_vpc.id  
  cidr_block              = "192.168.3.0/24"
  map_public_ip_on_launch = true
  availability_zone       = var.ZONE3
  
  tags = {
    Name = "Public_Subnet_3"
  }
}

# Private Subnets
resource "aws_subnet" "private_subnet_1" {
  vpc_id                  = aws_vpc.mongo_vpc.id  
  cidr_block              = "192.168.4.0/24"
  map_public_ip_on_launch = false
  availability_zone       = var.ZONE1
  
  tags = {
    Name = "Private_Subnet_1"
  }
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id                  = aws_vpc.mongo_vpc.id  
  cidr_block              = "192.168.5.0/24"
  map_public_ip_on_launch = false
  availability_zone       = var.ZONE2
  
  tags = {
    Name = "Private_Subnet_2"
  }
}

resource "aws_subnet" "private_subnet_3" {
  vpc_id                  = aws_vpc.mongo_vpc.id  
  cidr_block              = "192.168.6.0/24"
  map_public_ip_on_launch = false
  availability_zone       = var.ZONE3
  
  tags = {
    Name = "Private_Subnet_3"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "IGW" {
  vpc_id = aws_vpc.mongo_vpc.id  
  
  tags = {
    Name = "IGW"
  }
}

# Public Route Table
resource "aws_route_table" "public_RT" {
  vpc_id = aws_vpc.mongo_vpc.id  
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.IGW.id
  }
  
  tags = {
    Name = "Public_RT_Tasky"  
  }
}

# Route Table Associations for Public Subnets
resource "aws_route_table_association" "public_subnet_1a" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.public_RT.id
}

resource "aws_route_table_association" "public_subnet_2b" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public_RT.id
}

resource "aws_route_table_association" "public_subnet_3c" {
  subnet_id      = aws_subnet.public_subnet_3.id
  route_table_id = aws_route_table.public_RT.id
}

# ADDED: Outputs needed by main configuration
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.mongo_vpc.id  
}

output "subnet_id" {
  description = "ID of the first public subnet (for EC2 instance)"
  value       = aws_subnet.public_subnet_1.id
}

output "security_group_id" {
  description = "ID of the security group (for EC2 instance)"
  value       = aws_security_group.terraform_sg.id
}

# Additional useful outputs
output "public_subnet_ids" {
  description = "List of all public subnet IDs"
  value = [
    aws_subnet.public_subnet_1.id,
    aws_subnet.public_subnet_2.id,
    aws_subnet.public_subnet_3.id
  ]
}

output "private_subnet_ids" {
  description = "List of all private subnet IDs"
  value = [
    aws_subnet.private_subnet_1.id,
    aws_subnet.private_subnet_2.id,
    aws_subnet.private_subnet_3.id
  ]
}