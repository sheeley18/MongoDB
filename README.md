Example usage scenarios: 

# Test with
mongo mongodb://your-ec2-public-ip:27017
# or
mongosh mongodb://your-ec2-public-ip:27017



This db allows all connections just for PoC.

# Production example - restrict to specific IPs/VPCs
cidr_ipv4 = "YOUR_OFFICE_IP/32"        # Your office
# OR
cidr_ipv4 = "192.168.0.0/16"          # VPC only  
# OR 
cidr_ipv4 = "10.0.0.0/8"              # Private network only

To run:
terraform init
terraform plan    
terraform apply


Licensing: https://www.mongodb.com/legal/licensing/community-edition
