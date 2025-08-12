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

# Elastic IP for NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"
  
  tags = {
    Name = "NAT_EIP"
  }
  
  depends_on = [aws_internet_gateway.IGW]
}

# NAT Gateway in public subnet
resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet_1.id
  
  tags = {
    Name = "NAT_Gateway"
  }
  
  depends_on = [aws_internet_gateway.IGW]
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

# Private Route Table with NAT Gateway
resource "aws_route_table" "private_RT" {
  vpc_id = aws_vpc.mongo_vpc.id
  
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }
  
  tags = {
    Name = "Private_RT_Tasky"
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

# Route Table Associations for Private Subnets
resource "aws_route_table_association" "private_subnet_1a" {
  subnet_id      = aws_subnet.private_subnet_1.id
  route_table_id = aws_route_table.private_RT.id
}

resource "aws_route_table_association" "private_subnet_2b" {
  subnet_id      = aws_subnet.private_subnet_2.id
  route_table_id = aws_route_table.private_RT.id
}

resource "aws_route_table_association" "private_subnet_3c" {
  subnet_id      = aws_subnet.private_subnet_3.id
  route_table_id = aws_route_table.private_RT.id
}
