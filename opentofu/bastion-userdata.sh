#!/bin/bash
# Bastion Host User Data Script
# Installs kubectl and configures EKS cluster access

set -e

# Update system
dnf update -y

# Install required packages
dnf install -y curl unzip jq git

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# Install AWS CLI v2
cd /tmp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

# Configure kubectl for EKS
mkdir -p /home/ec2-user/.kube
aws eks update-kubeconfig --name ${cluster_name} --region ${region} --kubeconfig /home/ec2-user/.kube/config
chown -R ec2-user:ec2-user /home/ec2-user/.kube

# Also configure for root user
mkdir -p /root/.kube
aws eks update-kubeconfig --name ${cluster_name} --region ${region} --kubeconfig /root/.kube/config

# Create helper script for testing API
cat > /home/ec2-user/test-api.sh <<'EOF'
#!/bin/bash
# Helper script to test the Products API

echo "Testing Products API from bastion host..."
echo ""
echo "1. Checking if API pod is running:"
kubectl get pods -n data -l app=products-api
echo ""
echo "2. Testing API health endpoint (internal):"
kubectl run test-curl --image=curlimages/curl:latest -n data --rm -i --restart=Never -- curl -s http://products-api.data.svc.cluster.local:8080/health
echo ""
echo "3. Testing API products endpoint (internal):"
kubectl run test-curl --image=curlimages/curl:latest -n data --rm -i --restart=Never -- curl -s http://products-api.data.svc.cluster.local:8080/products
echo ""
echo "4. To access API via port-forward, run:"
echo "   kubectl port-forward -n data svc/products-api 8080:8080"
echo "   Then in another terminal: curl http://localhost:8080/products"
EOF

chmod +x /home/ec2-user/test-api.sh
chown ec2-user:ec2-user /home/ec2-user/test-api.sh

# Create welcome message
cat > /etc/motd <<'EOF'
================================================================================
  Bastion Host - EKS Cluster Access
================================================================================

This bastion host provides secure access to the EKS cluster and private APIs.

Quick Commands:
  - kubectl get nodes              # Check cluster nodes
  - kubectl get pods -A            # List all pods
  - kubectl get svc -n data        # List services in data namespace
  - ./test-api.sh                  # Test the Products API

To access the Products API:
  1. Port-forward: kubectl port-forward -n data svc/products-api 8080:8080
  2. Test: curl http://localhost:8080/products

EKS Cluster: ${cluster_name}
Region: ${region}
================================================================================
EOF

echo "Bastion host setup completed successfully!" > /var/log/userdata-complete.log
