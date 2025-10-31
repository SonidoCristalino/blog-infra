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

# Proveedor ALIADO para la región us-east-1 (requerido por ACM para CloudFront)
provider "aws" {
  alias  = "east"
  region = "us-east-1"
}

# 3. ¡El recurso! Creamos el bucket S3
resource "aws_s3_bucket" "blog_bucket" {
  # ¡IMPORTANTE! El nombre del bucket debe ser ÚNICO a nivel MUNDIAL.
  # Una buena práctica es usar tu dominio.
  # Reemplaza "universo25-com" por el dominio que PIENSAS usar.
  bucket = "universo25-com" 

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

# --- Sección de Dominio y Certificado SSL ---

# 6. Definir el nombre de tu dominio
variable "domain_name" {
  type        = string
  description = "universo-25.com"
  default     = "universo-25.com"
}

# 7. Obtener tu "Zona Hospedada" de Route 53
# (Debe existir previamente en tu cuenta de AWS)
data "aws_route53_zone" "primary" {
  name         = var.domain_name
  private_zone = false
}

# 8. Crear el Certificado SSL/TLS (HTTPS)
resource "aws_acm_certificate" "blog_cert" {
  # ¡IMPORTANTE! CloudFront REQUIERE que el certificado esté en "us-east-1"
  provider = aws.east
  
  domain_name       = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.domain_name} Cert"
  }
}

# 9. Crear el registro DNS para VALIDAR el certificado
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.blog_cert.domain_validation_options : dvo.domain_name => {
      name    = dvo.resource_record_name
      record  = dvo.resource_record_value
      type    = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.primary.zone_id
}

# 10. Esperar a que el certificado esté validado
resource "aws_acm_certificate_validation" "blog_cert_validation" {
  provider = aws.east
  
  certificate_arn         = aws_acm_certificate.blog_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# --- Sección de CloudFront (El CDN) ---

# 11. Crear la distribución de CloudFront (el CDN)
resource "aws_cloudfront_distribution" "blog_distribution" {

  # origin {
  #   # Apunta al bucket S3
  #   domain_name = aws_s3_bucket.blog_bucket.bucket_regional_domain_name
  #   origin_id   = "S3-${aws_s3_bucket.blog_bucket.id}"
  # }
  
  origin {
    # Apunta al ENDPOINT DEL SITIO WEB de S3 (¡el "inteligente"!)
    domain_name = aws_s3_bucket_website_configuration.blog_website_config.website_endpoint
    origin_id   = "S3-Website-${aws_s3_bucket.blog_bucket.id}"

    # Añadimos este bloque para decirle a CloudFront cómo hablar con el endpoint
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # Los S3 website endpoints solo hablan HTTP
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }
  
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CDN para ${var.domain_name}"
  default_root_object = "index.html"

  # Apuntar tu dominio (ej. universo-25.com) a la distribución
  aliases = [var.domain_name, "www.${var.domain_name}"]

  # Configuración de SSL/HTTPS
  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate_validation.blog_cert_validation.certificate_arn
    ssl_support_method  = "sni-only"
  }

  # Configuración de cómo CloudFront maneja el caché y los errores
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-Website-${aws_s3_bucket.blog_bucket.id}" 

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }
  
  # Manejo de errores (ej. redirigir 404 a index.html)
  custom_error_response {
    error_caching_min_ttl = 300
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
  }
  
  custom_error_response {
    error_caching_min_ttl = 300
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name        = "Blog CDN ${var.domain_name}"
    Environment = "Produccion"
    ManagedBy   = "Terraform"
  }
}

# 12. Crear el registro "A" en Route 53 para apuntar tu dominio al CDN
resource "aws_route53_record" "blog_domain" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.blog_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.blog_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

# 13. (Opcional) Crear el registro "A" para "www"
resource "aws_route53_record" "blog_domain_www" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.blog_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.blog_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}
