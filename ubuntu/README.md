# High Availability on AWS with Keepalived, ENI, and ProxySQL

This repository provides scripts to bootstrap **high availability** on AWS using:

- **Keepalived** for VRRP failover  
- **Elastic Network Interface (ENI)** for floating IP  
- **ProxySQL** as the database proxy being monitored  

Two EC2 instances are used:
- Node0 → Master
- Node1 → Backup

---

## Files

All scripts are in the [`ubuntu/`](./ubuntu) folder:

- [`ubuntu/setup_master.sh`](./ubuntu/setup_master.sh) → Run on the Master EC2 instance. Creates the ENI and configures Keepalived.  
- [`ubuntu/setup_backup.sh`](./ubuntu/setup_backup.sh) → Run on the Backup EC2 instance. Uses the ENI ID from the Master output.  
- [`ubuntu/README.md`](./ubuntu/README.md) → This documentation.

---

## Prerequisites

- Ubuntu 24.04 EC2 instances  
- IAM Role with permissions:
  - `ec2:DescribeNetworkInterfaces`
  - `ec2:AttachNetworkInterface`
  - `ec2:DetachNetworkInterface`
- Security Groups allowing:
  - TCP 6032, 6033 (ProxySQL)  
  - Protocol 112 (VRRP) between the two nodes  

---

## Usage

### 1. Master Node

Run:

```bash
cd ubuntu
chmod +x setup_master.sh
./setup_master.sh
