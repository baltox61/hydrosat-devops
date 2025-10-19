resource "aws_s3_bucket" "products" {
  bucket        = var.products_bucket
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

# Lifecycle policy: Delete data after 7 days (demo/test environment)
resource "aws_s3_bucket_lifecycle_configuration" "products" {
  bucket = aws_s3_bucket.products.id

  rule {
    id     = "delete-old-weather-data"
    status = "Enabled"

    # Delete current versions after 7 days
    expiration {
      days = 7
    }

    # Delete old versions after 1 day
    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    # Clean up incomplete multipart uploads after 1 day
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
