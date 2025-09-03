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

All scripts are in the [`ubuntu/`](./) folder:

- [`setup_master.sh`](./setup_master.sh) → Run on the Master EC2 instance. Creates the ENI and configures Keepalived.  
- [`setup_backup.sh`](./setup_backup.sh) → Run on the Backup EC2 instance. Uses the ENI ID from the Master output.  
- [`README.md`](./README.md) → This documentation.

---

## Prerequisites

- Ubuntu 24.04 EC2 instances  
- IAM Role with permissions:
  - `ec2:DescribeNetworkInterfaces`
  - `ec2:AttachNetworkInterface`
  - `ec2:DetachNetworkInterface`
- Security Groups allowing:
  - TCP 6032, 6033 (ProxySQL admin + client ports)  
  - Protocol 112 (VRRP) between the two nodes  

---

## Usage

### 1. Master Node

Run:

```bash
cd ubuntu
chmod +x setup_master.sh
./setup_master.sh
````

You will be asked for:

VIP

ENI description

Subnet ID

Security Group ID

Backup node IP

At the end, the script will output the ENI ID.
👉 Copy this ENI ID — you’ll need it for the Backup script.

2. Backup Node

Run:

cd ubuntu
chmod +x setup_backup.sh
./setup_backup.sh


You will be asked for:

ENI ID (from Master output)

VIP (same as Master)

Master node IP

This script will:

Attach the IAM role

Deploy Keepalived config with ProxySQL health check

Start Keepalived

Logging

Both scripts provide syslog-style logging with timestamps.

Example successful run:

Sep 02 18:42:15 [INFO] Creating ENI ... OK
Sep 02 18:42:17 [INFO] Attaching IAM Role ... OK
Sep 02 18:42:18 [INFO] Deploying eni-move.sh ... OK
Sep 02 18:42:19 [INFO] Starting Keepalived service ... OK


If something fails, the script stops immediately:

Sep 02 18:42:15 [INFO] Creating ENI ... FAIL

Failover Behavior

Keepalived monitors ProxySQL (127.0.0.1:6033).

If ProxySQL fails or the Master goes down:

ENI is detached from Master

ENI is attached to Backup

VIP becomes available on Backup

Topology Diagram
flowchart LR
    subgraph AWS VPC
        A[Master Node<br/>Keepalived + ProxySQL] 
        B[Backup Node<br/>Keepalived + ProxySQL] 
        E[(Elastic Network Interface<br/>VIP: 172.31.x.x)]
    end

    A -- VRRP (112) --> B
    A <-- VRRP (112) --> B
    A -- ProxySQL 6032/6033 --> Client[(Clients)]
    A <---> E
    B <---> E
    B -- ProxySQL 6032/6033 --> Client

Failover Sequence
sequenceDiagram
    participant Client
    participant Master
    participant ENI
    participant Backup

    Client->>Master: Send SQL traffic via VIP:6033
    Master->>ENI: Owns VIP (attached)
    Note over Master: ProxySQL running OK

    Master--xClient: Failure occurs (ProxySQL crash / host down)
    Master-->>ENI: Keepalived triggers detach
    ENI-->>Backup: ENI re-attached
    Backup->>ENI: Now owns VIP
    Client->>Backup: Resume SQL traffic via VIP:6033
    Note over Backup: ProxySQL now serves traffic

Notes

auth_pass is hardcoded as S3cR3tP@ (8 chars).

Use journalctl -u keepalived and tcpdump -i ens5 proto 112 for debugging.

These scripts are drafts / untested and should be validated before production.