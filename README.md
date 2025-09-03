# High Availability on AWS with Keepalived, ENI, and ProxySQL

This repository provides scripts to bootstrap **high availability** on AWS using:

- **Keepalived** for VRRP failover
- **Elastic Network Interface (ENI)** for floating IP
- **ProxySQL** as the database proxy being monitored

Two EC2 instances are used:
- Node0 → Master
- Node1 → Backup

## Files

- `setup_master.sh` → Run on the master EC2 instance.
- `setup_backup.sh` → Run on the backup EC2 instance.
- `README.md` → This documentation.

## Prerequisites

- Ubuntu 24.04 EC2 instances
- IAM Role with permissions:
  - `ec2:DescribeNetworkInterfaces`
  - `ec2:AttachNetworkInterface`
  - `ec2:DetachNetworkInterface`
- Security Groups allowing:
  - TCP 6032, 6033 (ProxySQL)
  - Protocol 112 (VRRP) between the two nodes

## Usage

### 1. Master Node

Run:

```bash
chmod +x setup_master.sh
./setup_master.sh

