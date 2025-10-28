# 1. Configura Terraform para que sepa que usaremos AWS
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  required_version = ">= 1.13.0"
}

# 2. Configura el "proveedor" (Provider) de AWS
# Le decimos que queremos operar en la región "us-east-1"
# (CloudFront requiere que los buckets estén en esta región)
provider "aws" {
  region = "us-east-1"
}

# 3. ¡El recurso! Creamos el bucket S3
resource "aws_s3_bucket" "blog_bucket" {
  # ¡IMPORTANTE! El nombre del bucket debe ser ÚNICO a nivel MUNDIAL.
  # Una buena práctica es usar tu dominio.
  # Reemplaza "universo25.com" por el dominio que PIENSAS usar.
  bucket = "universo25-com" # <--- ¡CAMBIA ESTO!

  tags = {
    Name        = "Blog Estatico Universo25"
    Environment = "Produccion"
    ManagedBy   = "Terraform"
  }
}

# 4. Configuramos el bucket para que funcione como un sitio web
resource "aws_s3_bucket_website_configuration" "blog_website_config" {
  bucket = aws_s3_bucket.blog_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "404.html"
  }
}

# 5. Hacemos el bucket PÚBLICO (para que la gente pueda leerlo)
# (Más adelante, CloudFront será el único que acceda, pero por ahora
# esto nos permite probar que el bucket funciona).
resource "aws_s3_bucket_public_access_block" "blog_public_access" {
  bucket = aws_s3_bucket.blog_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "blog_policy" {
  bucket = aws_s3_bucket.blog_bucket.id

  depends_on = [
    aws_s3_bucket_public_access_block.blog_public_access
  ]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "arn:aws:s3:::${aws_s3_bucket.blog_bucket.bucket}/*"
      }
    ]
  })
}
