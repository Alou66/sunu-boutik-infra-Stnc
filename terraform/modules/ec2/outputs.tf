output "frontend_instance_id" { value = aws_instance.frontend.id }
output "backend_instance_id" { value = aws_instance.backend.id }
output "database_instance_id" { value = aws_instance.database.id }
output "frontend_public_ip" { value = aws_eip.frontend.public_ip }
output "frontend_private_ip" { value = aws_instance.frontend.private_ip }
output "backend_private_ip" { value = aws_instance.backend.private_ip }
output "database_private_ip" { value = aws_instance.database.private_ip }
output "postgres_data_volume_id" { value = aws_ebs_volume.postgres_data.id }
