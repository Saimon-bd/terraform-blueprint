# EC2 instance for k3s Master Node in Private Subnet
resource "aws_instance" "master" {
  ami           = var.ubuntu_ami
  instance_type = var.instance_type
  subnet_id     = aws_subnet.private.id
  key_name      = aws_key_pair.k3s_key_pair.key_name
  vpc_security_group_ids = [aws_security_group.k3s_cluster.id]

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              sudo hostnamectl hostname master
              apt-get install -y curl
              curl -sfL https://get.k3s.io | sh -s - server --token=${random_password.k3s_token.result}
              
              while ! systemctl is-active --quiet k3s; do
                sleep 60
                echo "Waiting for k3s to start..."
              done
              sudo chmod 644 /etc/rancher/k3s/k3s.yaml
              echo "k3s master node is ready"
              EOF

  tags = {
    Name = "k3s-master"
  }
}

# EC2 instance for k3s Worker Node in Private Subnet
resource "aws_instance" "k3s_workers" {
  count         = 2
  ami           = var.ubuntu_ami
  instance_type = var.instance_type
  subnet_id     = aws_subnet.private.id
  key_name      = aws_key_pair.k3s_key_pair.key_name
  vpc_security_group_ids = [aws_security_group.k3s_cluster.id]

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y curl
              curl -sfL https://get.k3s.io | K3S_URL=https://${aws_instance.master.private_ip}:6443 K3S_TOKEN=${random_password.k3s_token.result} sh -
              EOF

  tags = {
    Name = "k3s-worker-${count.index + 1}"
  }

  depends_on = [aws_instance.master]
}

# Nginx Load Balancer in Public Subnet
resource "aws_instance" "nginx" {
  ami           = var.ubuntu_ami
  instance_type = var.instance_type
  subnet_id     = aws_subnet.public.id
  key_name      = aws_key_pair.k3s_key_pair.key_name
  vpc_security_group_ids = [aws_security_group.nginx.id]

  user_data = <<-EOF
              #!/bin/bash
              apt update
              apt install -y nginx
              sudo hostnamectl hostname nginx-lb

              # Create NGINX configuration for load balancing
              cat > /etc/nginx/nginx.conf <<EOL
              events {}

              http {
                  upstream react_app {
                      server react-app-service.default.svc.cluster.local:3000;
                  }

                  upstream flask_api {
                      server flask-api-service.default.svc.cluster.local:5000;
                  }

                  server {
                      listen 80;

                      # Route for the React app
                      location /app/ {
                          proxy_pass http://react_app;
                          proxy_set_header Host \$host;
                          proxy_set_header X-Real-IP \$remote_addr;
                          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                          proxy_set_header X-Forwarded-Proto \$scheme;
                      }

                      # Route for the Flask API
                      location /api/ {
                          proxy_pass http://flask_api;
                          proxy_set_header Host \$host;
                          proxy_set_header X-Real-IP \$remote_addr;
                          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                          proxy_set_header X-Forwarded-Proto \$scheme;
                      }
                  }
              }
              EOL

              systemctl restart nginx
              EOF

  tags = {
    Name = "nginx-lb"
  }

  depends_on = [aws_instance.master, aws_instance.k3s_workers]
}
