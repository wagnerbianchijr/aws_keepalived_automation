# AWS Keepalived Automation

![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu\&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-EC2%20%7C%20ENI-FF9900?logo=amazon-aws\&logoColor=white)
![Keepalived](https://img.shields.io/badge/Keepalived-v2.2.8-blue)
![ProxySQL](https://img.shields.io/badge/ProxySQL-2.x-green)
![AWS CLI](https://img.shields.io/badge/AWS%20CLI-Required-orange?logo=amazon-aws\&logoColor=white)
![Status](https://img.shields.io/badge/Status-Draft-yellow)
![Build](https://img.shields.io/badge/Build-Passing-brightgreen?logo=github-actions\&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-lightgrey)
![Contributions](https://img.shields.io/badge/Contributions-Welcome-blueviolet)

This repository provides automation scripts to configure **high availability** on AWS using:

* **Keepalived** for VRRP failover
* **Elastic Network Interface (ENI)** for floating IPs
* **ProxySQL** as the SQL proxy being monitored

The solution creates a floating VIP using an ENI, which automatically fails over between two EC2 instances running Keepalived + ProxySQL.

---

## Repository Structure

```
aws_keepalived_automation/
├── ubuntu/            # Scripts and docs for Ubuntu 24.04 setup
│   ├── README.md      # Detailed documentation
│   ├── setup_master.sh
│   └── setup_backup.sh
├── rocky/            # Scripts and docs for Rocky Linux setup
│   ├── README.md      # Detailed documentation
│   ├── setup_master.sh
│   └── setup_backup.sh
```

---

## Quick Start

1. Go to the [`ubuntu/`](./ubuntu) folder.
2. Follow the instructions in the [Ubuntu README](./ubuntu/README.md).
3. Run `setup_master.sh` on Node0 and `setup_backup.sh` on Node1.

---

## Features

* Automated creation and management of an ENI (Elastic Network Interface)
* Failover handling via Keepalived VRRP
* ProxySQL health-check integration
* Syslog-style logging with `[INFO] OK/FAIL` outputs

---

## Requirements

* Ubuntu 24.04 EC2 instances
* AWS CLI installed on each instance
* IAM role with permissions to manage ENIs (`Attach`, `Detach`, `Describe`)
* Security Groups allowing:

  * TCP ports `6032` and `6033` for ProxySQL
  * Protocol `112` for VRRP between nodes

---

## Documentation

👉 Full details and diagrams are in the [Ubuntu README](./ubuntu/README.md).

---

## Status

⚠️ This is a **draft implementation** and should be tested thoroughly before use in production.

---

## Contributing

Contributions are welcome! 🎉
Please fork this repository, open a feature branch, and submit a pull request.

---

## License

This project is licensed under the **MIT License** — see the [LICENSE](./LICENSE) file for details.