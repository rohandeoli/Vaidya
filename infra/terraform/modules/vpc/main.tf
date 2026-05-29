data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az_count = 2
  azs      = slice(data.aws_availability_zones.available.names, 0, local.az_count)
}

# ─────────────────────────────────────────────────────────────
# The VPC — the private network everything else lives inside.
# DNS support + hostnames are required for interface VPC endpoints
# to resolve AWS service names to their private IPs.
# ─────────────────────────────────────────────────────────────
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "medical-ai-${var.environment}"
  }
}

# The single door to the public internet, used only by public subnets.
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "medical-ai-igw-${var.environment}"
  }
}

# ─────────────────────────────────────────────────────────────
# Subnets — three tiers × 2 AZs
#   public:  ALB + NAT (internet-facing)
#   private: Fargate API + Lambda worker (outbound via NAT only)
#   data:    RDS + Redis (no internet route at all)
# ─────────────────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count                   = local.az_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "medical-ai-public-${local.azs[count.index]}-${var.environment}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "medical-ai-private-${local.azs[count.index]}-${var.environment}"
    Tier = "private"
  }
}

resource "aws_subnet" "data" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.data_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "medical-ai-data-${local.azs[count.index]}-${var.environment}"
    Tier = "data"
  }
}

# ─────────────────────────────────────────────────────────────
# NAT gateway — single, in the first public subnet (cost choice).
# Lets private-subnet resources reach the internet OUTBOUND only
# (Claude API, Cohere). Needs a static public IP (EIP).
# ─────────────────────────────────────────────────────────────
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "medical-ai-nat-${var.environment}"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "medical-ai-nat-${var.environment}"
  }

  depends_on = [aws_internet_gateway.this]
}

# ─────────────────────────────────────────────────────────────
# Route tables
#   public  -> 0.0.0.0/0 via IGW
#   private -> 0.0.0.0/0 via NAT
#   data    -> local only (fully isolated from the internet)
# ─────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "medical-ai-public-${var.environment}"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "medical-ai-private-${var.environment}"
  }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count          = local.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "medical-ai-data-${var.environment}"
  }
}

resource "aws_route_table_association" "data" {
  count          = local.az_count
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# ─────────────────────────────────────────────────────────────
# Subnet groups — RDS and ElastiCache require a named set of
# subnets (across both AZs) to place primary/standby nodes in.
# Both live in the data tier.
# ─────────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "this" {
  name       = "medical-ai-${var.environment}"
  subnet_ids = aws_subnet.data[*].id

  tags = {
    Name = "medical-ai-db-subnet-group-${var.environment}"
  }
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "medical-ai-${var.environment}"
  subnet_ids = aws_subnet.data[*].id
}
