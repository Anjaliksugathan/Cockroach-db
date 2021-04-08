provider "aws"{
}
variable "region_number" {
  # Arbitrary mapping of region name to number to use in
  # a VPC's CIDR prefix.
  default = {
    us-east-1      = 1
    us-west-1      = 2
    us-west-2      = 3
    eu-central-1   = 4
    ap-northeast-1 = 5
  }
}

variable "az_number" {
  # Assign a number to each AZ letter used in our configuration
  default = {
    a = 1
    b = 2
    c = 3
    d = 4
    e = 5
    f = 6
  }
}


# Retrieve the AZ where we want to create network resources
# This must be in the region selected on the AWS provider.
data "aws_availability_zones" "example" { }
# Create a VPC for the region associated with the AZ
resource "aws_vpc" "myvpc" {
  cidr_block = cidrsubnet("10.0.0.0/8", 4, var.region_number)
}

# Create a subnet for the AZ within the regional VPC
resource "aws_subnet" "examplee" {
  vpc_id     = aws_vpc.myvpc.id
  cidr_block = cidrsubnet(aws_vpc.myvpc.cidr_block, 4, var.az_number[data.aws_availability_zones.example])
}

# Internet gateway for the public subnets
resource "aws_internet_gateway" "myInternetGateway" {
  vpc_id = aws_vpc.myvpc.id

  tags= {
    Name = "myInternetGateway"
  }
}

resource "aws_route_table" "rtblPublic" {
  vpc_id = aws_vpc.myvpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "aws_internet_gateway.myInternetGateway.id"
  }

  tags= {
    Name = "rtblPublic"
  }
}

resource "aws_route_table_association" "route"{
  count          = length(data.aws_availability_zones.example)
  subnet_id      = element(aws_subnet.examplee.*.id, count.index)
  route_table_id = aws_route_table.rtblPublic.id
}

# Elastic IP for NAT gateway
resource "aws_eip" "nat" {
  vpc = true
}

# NAT Gateway
resource "aws_nat_gateway" "nat-gw" {
  allocation_id = aws_eip.nat.id
  subnet_id     = element(aws_subnet.examplee.*.id, 1)
  depends_on    = [aws_internet_gateway.myInternetGateway]
}

# Routing table for private subnets
resource "aws_route_table" "rtblPrivate" {
  vpc_id = aws_vpc.myvpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = "aws_nat_gateway.nat-gw.id"
  }

  tags= {
    Name = "rtblPrivate"
  }
}

resource "aws_route_table_association" "private_route" {
  count          = length(data.aws_availability_zones.example)
  subnet_id      = element(aws_subnet.examplee.*.id, count.index)
  route_table_id = aws_route_table.rtblPrivate.id
}
resource "aws_security_group" "sg" {
vpc_id=aws_vpc.myvpc.id

 dynamic "ingress" {
    for_each = var.ingress_rules
    content {
      description      = lookup(ingress.value, "description", null)
      from_port        = lookup(ingress.value, "from_port", null)
      to_port          = lookup(ingress.value, "to_port", null)
      protocol         = lookup(ingress.value, "protocol", null)
      cidr_blocks      = lookup(ingress.value, "cidr_blocks", null)
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}
resource "aws_elb" "appdb" {
  name               = "appdb-terraform-elb"
  availability_zones = ["us-east-1a","us-east-1b","us-east-1c"]

  listener {
    instance_port     = "26257"
    instance_protocol = "tcp"
    lb_port           = "26257"
    lb_protocol       = "tcp"
  }

  listener {
    instance_port      = "8080"
    instance_protocol  = "http"
    lb_port            = "8080"
    lb_protocol        = "https"
    ssl_certificate_id = "arn:aws:acm:eu-west-1:235367859451:certificate/6c270328-2cd5-4b2d-8dfd-ae8d0004ad31"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:8000/"
    interval            = 30
  }

  tags = {
    Name = "appdb-terraform-elb"
  }
}
resource "aws_instance" "app" {

subnet_id      = "{element(aws_subnet.examplee.*.id, count.index)}"


ami = "ami-0742b4e673072066f"
instance_type = "t2.micro"
vpc_security_group_ids = [aws_security_group.sg.id]
count=3
user_data=<<EOF
#!/bin/bash
sudo yum update -y
sudo yum erase 'ntp*'
sudo yum install chrony
sudo service chronyd restart
mkdir certs
mkdir my-safe-directory
cockroach cert create-ca --certs-dir=certs --ca-key=my-safe-directory/ca.key
cockroach cert create-node <node1 internal IP address> <node1 external IP address> <node1 hostname>  <other common names for node1> localhost 127.0.0.1 <load balancer IP address> <load balancer hostname>  <other common names for load balancer instances> --certs-dir=certs --ca-key=my-safe-directory/ca.key
ssh-add /path/<key file>.pem
ssh <username>@<node1 DNS name> "mkdir certs"
scp certs/ca.crt certs/node.crt certs/node.key <username>@<node1 DNS name>:~/certs
rm certs/node.crt certs/node.key
cockroach cert create-node <node2 internal IP address> <node2 external IP address> <node2 hostname>  <other common names for node2> localhost 127.0.0.1 <load balancer IP address> <load balancer hostname>  <other common names for load balancer instances> --certs-dir=certs --ca-key=my-safe-directory/ca.key
ssh <username>@<node2 DNS name> "mkdir certs"
scp certs/ca.crt certs/node.crt certs/node.key <username>@<node2 DNS name>:~/certs
cockroach cert create-client root --certs-dir=certs --ca-key=my-safe-directory/ca.key
ssh <username>@<workload address> "mkdir certs"
scp certs/ca.crt certs/client.root.crt certs/client.root.key <username>@<workload address>:~/certs
wget -qO- https://binaries.cockroachdb.com/cockroach-v20.2.7.linux-amd64.tgz | tar  xvz
cp -i cockroach-v20.2.7.linux-amd64/cockroach /usr/local/bin/
mkdir -p /usr/local/lib/cockroach
cp -i cockroach-v20.2.7.linux-amd64/lib/libgeos.so /usr/local/lib/cockroach/
cp -i cockroach-v20.2.7.linux-amd64/lib/libgeos_c.so /usr/local/lib/cockroach/
cockroach start --certs-dir=certs --advertise-addr=<node1 address> --join=<node1 address>,<node2 address>,<node3 address> --cache=.25 --max-sql-memory=.25 --background
cockroach init --certs-dir=certs --host=<address of any node>
cockroach sql --certs-dir=certs --host=<address of load balancer>
CREATE DATABASE securenodetest;
wget -qO- https://binaries.cockroachdb.com/cockroach-v20.2.7.linux-amd64.tgz | tar  xvz
cp -i cockroach-v20.2.7.linux-amd64/cockroach /usr/local/bin/
cockroach workload init tpcc 'postgresql://root@<IP ADDRESS OF LOAD BALANCER>:26257/tpcc?sslmode=verify-full&sslrootcert=certs/ca.crt&sslcert=certs/client.root.crt&sslkey=certs/client.root.key'
cockroach workload run tpcc --duration=10m 'postgresql://root@<IP ADDRESS OF LOAD BALANCER>:26257/tpcc?sslmode=verify-full&sslrootcert=certs/ca.crt&sslcert=certs/client.root.crt&sslkey=certs/client.root.key'
wget -qO- https://binaries.cockroachdb.com/cockroach-v20.2.7.linux-amd64.tgz | tar  xvz
cp -i cockroach-v20.2.7.linux-amd64/cockroach /usr/local/bin/
cockroach start --certs-dir=certs --advertise-addr=<node4 address> --join=<node1 address>,<node2 address>,<node3 address> --cache=.25 --max-sql-memory=.25 --background
EOF
}

