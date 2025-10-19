#!/bin/bash
#
# Setup DNS Aliases for Dagster Demo Services
#
# This script adds entries to /etc/hosts to provide friendly URLs for demo services
# It maps AWS LoadBalancer hostnames to easy-to-remember local domain names
#
# Usage:
#   ./scripts/setup_dns_aliases.sh           # Add aliases
#   ./scripts/setup_dns_aliases.sh remove    # Remove aliases
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Domain suffix for local development
DOMAIN="dagster.local"

# Markers for /etc/hosts entries
START_MARKER="# BEGIN DAGSTER DEMO SERVICES"
END_MARKER="# END DAGSTER DEMO SERVICES"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       Dagster Demo - DNS Aliases Setup                    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo

# Function to get LoadBalancer hostname
get_lb_hostname() {
    local service=$1
    local namespace=$2

    kubectl get svc "$service" -n "$namespace" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo ""
}

# Function to resolve hostname to IP
resolve_hostname() {
    local hostname=$1

    # Use dig if available, otherwise host
    if command -v dig &> /dev/null; then
        dig +short "$hostname" | head -1
    elif command -v host &> /dev/null; then
        host "$hostname" | grep "has address" | awk '{print $4}' | head -1
    else
        echo -e "${YELLOW}Warning: Neither 'dig' nor 'host' command found. Cannot resolve hostname.${NC}"
        echo ""
    fi
}

# Function to remove old entries
remove_aliases() {
    echo -e "${YELLOW}Removing existing Dagster demo aliases from /etc/hosts...${NC}"

    # Check if markers exist
    if grep -q "$START_MARKER" /etc/hosts 2>/dev/null; then
        # Create temp file without the marked section
        sudo sed -i.bak "/$START_MARKER/,/$END_MARKER/d" /etc/hosts
        echo -e "${GREEN}✓ Removed old aliases${NC}"
    else
        echo -e "${BLUE}ℹ No existing aliases found${NC}"
    fi
}

# Function to add aliases
add_aliases() {
    echo -e "${BLUE}Fetching service information from Kubernetes...${NC}\n"

    # Get LoadBalancer hostnames
    echo -e "Getting Grafana LoadBalancer..."
    GRAFANA_LB=$(get_lb_hostname "kps-grafana" "monitoring")

    echo -e "Getting Prometheus LoadBalancer..."
    PROMETHEUS_LB=$(get_lb_hostname "kps-kube-prometheus-stack-prometheus" "monitoring")

    echo -e "Getting API LoadBalancer..."
    API_LB=$(get_lb_hostname "products-api" "data")

    # Resolve hostnames to IPs
    if [ -n "$GRAFANA_LB" ]; then
        echo -e "\nResolving Grafana hostname..."
        GRAFANA_IP=$(resolve_hostname "$GRAFANA_LB")
    fi

    if [ -n "$PROMETHEUS_LB" ]; then
        echo -e "Resolving Prometheus hostname..."
        PROMETHEUS_IP=$(resolve_hostname "$PROMETHEUS_LB")
    fi

    if [ -n "$API_LB" ]; then
        echo -e "Resolving API hostname..."
        API_IP=$(resolve_hostname "$API_LB")
    fi

    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

    # Build /etc/hosts entries
    HOSTS_ENTRIES="$START_MARKER"
    HOSTS_ENTRIES+="\n# Auto-generated entries for Dagster demo services"
    HOSTS_ENTRIES+="\n# Created: $(date)"
    HOSTS_ENTRIES+="\n"

    # Add Grafana
    if [ -n "$GRAFANA_IP" ]; then
        HOSTS_ENTRIES+="\n${GRAFANA_IP}    grafana.${DOMAIN}"
        echo -e "${GREEN}✓ Grafana:    http://grafana.${DOMAIN}${NC}"
        echo -e "  LoadBalancer: $GRAFANA_LB"
        echo -e "  IP: $GRAFANA_IP"
        echo
    else
        echo -e "${YELLOW}⚠ Grafana LoadBalancer not ready or DNS not resolved${NC}\n"
    fi

    # Add Prometheus
    if [ -n "$PROMETHEUS_IP" ]; then
        HOSTS_ENTRIES+="\n${PROMETHEUS_IP}    prometheus.${DOMAIN}"
        echo -e "${GREEN}✓ Prometheus: http://prometheus.${DOMAIN}:9090${NC}"
        echo -e "  LoadBalancer: $PROMETHEUS_LB"
        echo -e "  IP: $PROMETHEUS_IP"
        echo
    else
        echo -e "${YELLOW}⚠ Prometheus LoadBalancer not ready or DNS not resolved${NC}\n"
    fi

    # Add API
    if [ -n "$API_IP" ]; then
        HOSTS_ENTRIES+="\n${API_IP}    api.${DOMAIN}"
        echo -e "${GREEN}✓ API:        http://api.${DOMAIN}:8080${NC}"
        echo -e "  LoadBalancer: $API_LB"
        echo -e "  IP: $API_IP"
        echo
    else
        echo -e "${YELLOW}⚠ API LoadBalancer not ready or DNS not resolved${NC}\n"
    fi

    # Add localhost aliases for port-forwarded services
    HOSTS_ENTRIES+="\n"
    HOSTS_ENTRIES+="\n# Port-forwarded services (use kubectl port-forward)"
    HOSTS_ENTRIES+="\n127.0.0.1    dagster.${DOMAIN}      # kubectl port-forward -n data svc/dagster-dagster-webserver 3001:80"
    HOSTS_ENTRIES+="\n127.0.0.1    alertmanager.${DOMAIN} # kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-alertmanager 9093:9093"

    HOSTS_ENTRIES+="\n$END_MARKER"

    # Check if we have any valid entries
    if [ -z "$GRAFANA_IP" ] && [ -z "$PROMETHEUS_IP" ] && [ -z "$API_IP" ]; then
        echo -e "${RED}✗ No LoadBalancers are ready with resolved IPs${NC}"
        echo -e "${YELLOW}  Please wait for LoadBalancers to be provisioned and try again.${NC}"
        echo
        echo -e "${BLUE}  Check status with:${NC}"
        echo -e "  kubectl get svc -n monitoring kps-grafana"
        echo -e "  kubectl get svc -n monitoring kps-kube-prometheus-stack-prometheus"
        echo -e "  kubectl get svc -n data products-api"
        exit 1
    fi

    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

    # Remove old entries first
    remove_aliases

    # Add new entries
    echo -e "${YELLOW}Adding new aliases to /etc/hosts...${NC}"
    echo -e "$HOSTS_ENTRIES" | sudo tee -a /etc/hosts > /dev/null

    echo -e "${GREEN}✓ Successfully added DNS aliases!${NC}\n"

    # Print summary
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    ACCESS YOUR SERVICES                    ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo

    if [ -n "$GRAFANA_IP" ]; then
        echo -e "${GREEN}Grafana Dashboard:${NC}"
        echo -e "  🌐 http://grafana.${DOMAIN}"
        echo -e "  👤 Username: admin"
        echo -e "  🔑 Password: prom-operator"
        echo
    fi

    if [ -n "$PROMETHEUS_IP" ]; then
        echo -e "${GREEN}Prometheus:${NC}"
        echo -e "  🌐 http://prometheus.${DOMAIN}:9090"
        echo
    fi

    if [ -n "$API_IP" ]; then
        echo -e "${GREEN}Weather Products API:${NC}"
        echo -e "  🌐 http://api.${DOMAIN}:8080/products"
        echo
    fi

    echo -e "${BLUE}Port-forwarded Services:${NC}"
    echo -e "  Run: ${YELLOW}kubectl port-forward -n data svc/dagster-dagster-webserver 3001:80${NC}"
    echo -e "  Then: http://dagster.${DOMAIN}:3001"
    echo
    echo -e "  Run: ${YELLOW}kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-alertmanager 9093:9093${NC}"
    echo -e "  Then: http://alertmanager.${DOMAIN}:9093"
    echo

    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

    echo -e "${GREEN}✅ Setup complete!${NC}\n"
}

# Main script logic
case "${1:-}" in
    remove)
        remove_aliases
        echo -e "${GREEN}✓ DNS aliases removed${NC}\n"
        ;;
    *)
        add_aliases
        ;;
esac

echo -e "${BLUE}Tip: To remove these aliases later, run:${NC}"
echo -e "  ./scripts/setup_dns_aliases.sh remove"
echo
