resource "aws_s3_bucket" "products" {
  bucket = var.products_bucket
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "products" {
  bucket = aws_s3_bucket.products.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "products" {
  bucket                  = aws_s3_bucket.products.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
