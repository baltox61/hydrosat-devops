#!/bin/bash
#
# Setup DNS Aliases for Dagster Demo Services
#
# This script adds entries to /etc/hosts to provide friendly localhost URLs
# All services are accessed via kubectl port-forward for simplicity and security
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
    echo -e "${BLUE}Verifying Kubernetes services exist...${NC}\n"

    # Check if required services exist
    if ! kubectl get svc kps-grafana -n monitoring &>/dev/null; then
        echo -e "${RED}✗ Grafana service not found${NC}"
        exit 1
    fi

    if ! kubectl get svc kps-kube-prometheus-stack-prometheus -n monitoring &>/dev/null; then
        echo -e "${RED}✗ Prometheus service not found${NC}"
        exit 1
    fi

    if ! kubectl get svc dagster-dagster-webserver -n data &>/dev/null; then
        echo -e "${RED}✗ Dagster service not found${NC}"
        exit 1
    fi

    if ! kubectl get svc products-api -n data &>/dev/null; then
        echo -e "${RED}✗ API service not found${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ All required services found${NC}\n"

    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

    # Build /etc/hosts entries - all using localhost
    HOSTS_ENTRIES="$START_MARKER"
    HOSTS_ENTRIES+="\n# Auto-generated entries for Dagster demo services"
    HOSTS_ENTRIES+="\n# Created: $(date)"
    HOSTS_ENTRIES+="\n# All services accessed via kubectl port-forward"
    HOSTS_ENTRIES+="\n"
    HOSTS_ENTRIES+="\n127.0.0.1    grafana.${DOMAIN}"
    HOSTS_ENTRIES+="\n127.0.0.1    prometheus.${DOMAIN}"
    HOSTS_ENTRIES+="\n127.0.0.1    dagster.${DOMAIN}"
    HOSTS_ENTRIES+="\n127.0.0.1    api.${DOMAIN}"
    HOSTS_ENTRIES+="\n127.0.0.1    alertmanager.${DOMAIN}"
    HOSTS_ENTRIES+="\n$END_MARKER"

    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

    # Remove old entries first
    remove_aliases

    # Add new entries
    echo -e "${YELLOW}Adding new aliases to /etc/hosts...${NC}"
    echo -e "$HOSTS_ENTRIES" | sudo tee -a /etc/hosts > /dev/null

    echo -e "${GREEN}✓ Successfully added DNS aliases!${NC}\n"

    # Print summary with port-forward commands
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              START PORT-FORWARDING & ACCESS                 ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo

    echo -e "${GREEN}1. Grafana Dashboard:${NC}"
    echo -e "   ${YELLOW}kubectl port-forward -n monitoring svc/kps-grafana 8001:80${NC}"
    echo -e "   🌐 http://grafana.${DOMAIN}:8001"
    echo -e "   👤 Username: ${BLUE}admin${NC}"
    echo -e "   🔑 Password: ${BLUE}prom-operator${NC}"
    echo

    echo -e "${GREEN}2. Prometheus:${NC}"
    echo -e "   ${YELLOW}kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090${NC}"
    echo -e "   🌐 http://prometheus.${DOMAIN}:9090"
    echo

    echo -e "${GREEN}3. Dagster UI:${NC}"
    echo -e "   ${YELLOW}kubectl port-forward -n data svc/dagster-dagster-webserver 3000:80${NC}"
    echo -e "   🌐 http://dagster.${DOMAIN}:3000"
    echo

    echo -e "${GREEN}4. Weather Products API:${NC}"
    echo -e "   ${YELLOW}kubectl port-forward -n data svc/products-api 8080:8080${NC}"
    echo -e "   🌐 http://api.${DOMAIN}:8080/products"
    echo

    echo -e "${GREEN}5. AlertManager (optional):${NC}"
    echo -e "   ${YELLOW}kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-alertmanager 9093:9093${NC}"
    echo -e "   🌐 http://alertmanager.${DOMAIN}:9093"
    echo

    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

    echo -e "${GREEN}✅ DNS aliases configured!${NC}"
    echo -e "${YELLOW}⚠  Remember: You need to run the port-forward commands above${NC}"
    echo -e "${YELLOW}   to access services via the friendly URLs${NC}\n"
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
