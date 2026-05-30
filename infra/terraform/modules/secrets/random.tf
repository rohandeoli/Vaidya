resource "random_password" "rds_master" {
  length  = 32
  special = true
  # RDS for Postgres disallows /, ", @, and spaces in the master password.
  override_special = "!#$%^&*()-_=+[]{}:?"
}

resource "random_password" "redis_auth_token" {
  length  = 64
  special = true
  # ElastiCache auth tokens only permit this restricted set of specials.
  override_special = "!&#$^<>-"
}
