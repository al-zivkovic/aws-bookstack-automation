#!/bin/bash

# define variables for CIDR and AZ
VPC_CIDR="10.0.0.0/16"
AZ="us-west-2"

# Create a new VPC
vpc_id=$(aws ec2 create-vpc --cidr-block $VPC_CIDR | yq '.Vpc.VpcId')
echo "VPC ID $vpc_id"

# Create a new subnet in the VPC created above
# For longer commands you can use \ to split up your command into several lines

# Public Subnet
public_subnet_cidr="10.0.1.0/24"
public_subnet_id=$(
  aws ec2 create-subnet \
  --cidr-block $public_subnet_cidr \
  --availability-zone ${AZ}a \
  --vpc-id $vpc_id \
  | yq '.Subnet.SubnetId'
)
echo "Subnet ID $public_subnet_id"

# Private Subnet 1
private_subnet_cidr="10.0.2.0/24"
private_subnet_id=$(
  aws ec2 create-subnet \
  --cidr-block $private_subnet_cidr \
  --availability-zone ${AZ}b \
  --vpc-id $vpc_id \
  | yq '.Subnet.SubnetId'
)
echo "Subnet ID $private_subnet_id"

# Private Subnet 2
private_subnet_cidr_2="10.0.3.0/24"
private_subnet_id_2=$(
  aws ec2 create-subnet \
  --cidr-block $private_subnet_cidr_2 \
  --availability-zone ${AZ}c \
  --vpc-id $vpc_id \
  | yq '.Subnet.SubnetId'
)
echo "Subnet ID $private_subnet_id_2"

# Internet Gateway
gateway_id=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region $AZ)
aws ec2 attach-internet-gateway \
  --internet-gateway-id $gateway_id \
  --vpc-id $vpc_id \
  --region $AZ

echo "Gateway ID $gateway_id"

# Route Table
route_table=$(aws ec2 create-route-table \
  --vpc-id $vpc_id \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region $AZ
  )

echo "Route Table ID $route_table"

aws ec2 create-route \
  --route-table-id $route_table \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $gateway_id \
  --region $AZ

aws ec2 associate-route-table \
  --subnet-id $public_subnet_id \
  --route-table-id $route_table \
  --region $AZ

# EC2 Security Group
ec2_security_group_id=$(aws ec2 create-security-group \
  --group-name "ec2-security-group" \
  --description "ec2 security group" \
  --vpc-id $vpc_id \
  --query 'GroupId' \
  --output text \
  --region $AZ
  )

echo "EC2 Security Group ID $ec2_security_group_id"

aws ec2 authorize-security-group-ingress \
  --group-id $ec2_security_group_id \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 \
  --region $AZ

aws ec2 authorize-security-group-ingress \
  --group-id $ec2_security_group_id \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region $AZ

# RDS Security Group
rds_security_group_id=$(aws ec2 create-security-group \
  --group-name "rds-security-group" \
  --description "rds security group" \
  --vpc-id $vpc_id \
  --query 'GroupId' \
  --output text \
  --region $AZ
  )

echo "RDS Security Group ID $rds_security_group_id"

aws ec2 authorize-security-group-ingress \
  --group-id $rds_security_group_id \
  --protocol tcp \
  --port 3306 \
  --source-group $ec2_security_group_id \
  --region $AZ

# RDS Subnet Group
aws rds create-db-subnet-group \
  --db-subnet-group-name "rds-subnet-group" \
  --db-subnet-group-description "rds subnet group" \
  --subnet-ids $private_subnet_id $private_subnet_id_2 \
  --region $AZ

# SSH Keypair
key="assignment2-key"
key_pair=$(aws ec2 create-key-pair \
  --key-name $key \
  --key-type ed25519 \
  --query 'KeyMaterial' \
  --output text \
  --region $AZ)
echo "$key_pair" > "${key}.pem"

chmod 600 ${key}.pem

# EC2 Instance
ami_id="ami-0735c191cf914754d"
ec2_info=$(aws ec2 run-instances \
  --image-id $ami_id \
  --count 1 \
  --instance-type t2.micro \
  --key-name $key \
  --security-group-ids $ec2_security_group_id \
  --subnet-id $public_subnet_id \
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=assignment2-ec2-instance}]' \
  --region $AZ \
  --query 'Instances[0].{InstanceId:InstanceId, PublicIpAddress:PublicIpAddress}' \
  --output json
)


# wait for ec2
echo "Wait for EC2 Instance to get created (it will take a bit of time...)"

instance_id=$(echo $ec2_info | yq -r '.InstanceId')
aws ec2 wait instance-running --instance-ids $instance_id

# RDS Instance
rds_sng="rds-subnet-group"
aws rds create-db-instance \
  --db-instance-identifier "rds-database-1" \
  --db-instance-class "db.t3.micro" \
  --engine "mysql" \
  --master-username "admin" \
  --master-user-password "password" \
  --allocated-storage 20 \
  --storage-type gp2 \
  --no-publicly-accessible \
  --vpc-security-group-ids $rds_security_group_id \
  --db-subnet-group-name $rds_sng

# wait for rds
echo "Wait for Database to get created (it will take a bit of time...)"


# Get public IP of the instance
public_ip=$(aws ec2 describe-instances --instance-ids $instance_id --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

if [ -z "$public_ip" ]
then
    echo "Error: Public IP not found for instance: $instance_id"
    exit 1
fi

# Copy application to EC2 Instance
key_file="./assignment2-key.pem"
copy_application=$(scp -o StrictHostKeyChecking=no -i "$key_file" ./application.sh ubuntu@$public_ip:~/)
if [ $? -ne 0 ]
then
    echo "Error: Failed to copy application to EC2 Instance"
    exit 1
else
    echo "Application copied to EC2 Instance"
fi

# Describe infrastructure
echo ""
echo "Describe infrastructure:"
aws ec2 describe-vpcs


