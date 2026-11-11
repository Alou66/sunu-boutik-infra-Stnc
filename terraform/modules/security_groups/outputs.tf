output "sg_frontend_id" { value = aws_security_group.frontend.id }
output "sg_backend_id" { value = aws_security_group.backend.id }
output "sg_database_id" { value = aws_security_group.database.id }
