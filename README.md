# OpenShift on AWS — Terraform (IPI)

Terraform wrapper for deploying a Red Hat OpenShift Container Platform cluster on AWS using the **Installer Provisioned Infrastructure (IPI)** method. Exposes the most commonly tuned parameters — master count, worker count, and instance types — while keeping everything else sensible by default.

---

## Prerequisites

| Tool | Minimum Version | Install |
|------|----------------|---------|
| `terraform` | 1.5.0 | https://developer.hashicorp.com/terraform/install |
| `openshift-install` | 4.14+ | https://mirror.openshift.com/pub/openshift-v4/clients/ocp/ |
| `oc` | 4.14+ | https://mirror.openshift.com/pub/openshift-v4/clients/ocp/ |
| `aws` CLI | 2.x | https://aws.amazon.com/cli/ |
| `jq` | 1.6+ | https://jqlang.github.io/jq/ |

### Installing Terraform

Terraform orchestrates the installation. Minimum required version is **1.5.0**.

**macOS — Homebrew (recommended)**
```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform version
```

**macOS — Manual**
```bash
curl -sLO https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_darwin_arm64.zip
unzip terraform_1.9.8_darwin_arm64.zip
sudo mv terraform /usr/local/bin/
terraform version
```
> Use `darwin_amd64` for Intel Macs. Check the [latest release](https://releases.hashicorp.com/terraform/) for the current version number.

**Linux — Package manager**
```bash
# Debian / Ubuntu
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install terraform

# RHEL / CentOS / Fedora
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo yum install terraform
```

**Linux — Manual**
```bash
curl -sLO https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
unzip terraform_1.9.8_linux_amd64.zip
sudo mv terraform /usr/local/bin/
terraform version
```

**Windows — Chocolatey**
```powershell
choco install terraform
```

**Windows — Winget**
```powershell
winget install --id Hashicorp.Terraform
```

Verify the installation:
```bash
terraform version
# Terraform v1.9.8 (or later)
```

---

### Installing OpenShift CLI Tools

Both `openshift-install` and `oc` must match (or be compatible with) the target OpenShift version.

**Step 1 — Find your target version**

Browse available releases at:
```
https://mirror.openshift.com/pub/openshift-v4/clients/ocp/
```

**Step 2 — Download and install (macOS / Linux)**
```bash
OCP_VERSION="4.16.3"   # set to your target version

# openshift-install
curl -sLO "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-install-linux.tar.gz"
tar -xzf openshift-install-linux.tar.gz
sudo mv openshift-install /usr/local/bin/
chmod +x /usr/local/bin/openshift-install

# oc CLI
curl -sLO "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-client-linux.tar.gz"
tar -xzf openshift-client-linux.tar.gz
sudo mv oc kubectl /usr/local/bin/
chmod +x /usr/local/bin/oc

# Verify
openshift-install version
oc version --client
```

> macOS users: replace `linux` with `mac` in the URLs above (e.g. `openshift-install-mac.tar.gz`).

---

### Installing AWS CLI v2

**macOS**
```bash
curl -sL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o /tmp/AWSCLIV2.pkg
sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
aws --version
```

**Linux**
```bash
curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install
aws --version
```

**Windows**
Download and run the MSI installer:
```
https://awscli.amazonaws.com/AWSCLIV2.msi
```

---

### Installing jq

```bash
# macOS
brew install jq

# Debian / Ubuntu
sudo apt-get install -y jq

# RHEL / CentOS / Fedora
sudo yum install -y jq

# Manual (Linux)
curl -sLo /usr/local/bin/jq https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64
chmod +x /usr/local/bin/jq
```

Verify all tools are ready:
```bash
terraform version
openshift-install version
oc version --client
aws --version
jq --version
```

---

### AWS Authentication

Terraform uses the standard AWS credential chain. Choose one method:

**Option 1 — Named profile (recommended for local use)**
```bash
aws configure --profile ocp-installer
# then set in terraform.tfvars:
aws_profile = "ocp-installer"
```

**Option 2 — Environment variables (recommended for CI/CD)**
```bash
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."     # only for temporary/STS credentials
# leave aws_profile empty in terraform.tfvars
```

**Option 3 — IAM Instance Role**
No configuration needed when running on EC2/ECS/EKS — the provider picks up the role automatically.

Verify credentials are working before applying:
```bash
aws sts get-caller-identity
```

### AWS Permission Check

Before running `terraform apply`, verify your credentials have all the required IAM permissions for OpenShift IPI. The script uses `aws iam simulate-principal-policy` — no real resources are created.

```bash
chmod +x scripts/check-aws-permissions.sh

# Using default credentials
./scripts/check-aws-permissions.sh

# Using a named profile
./scripts/check-aws-permissions.sh --profile ocp-installer

# Show pass/fail for every individual action
./scripts/check-aws-permissions.sh --verbose
```

The script checks permissions across six service groups:

| Group | Key Actions |
|-------|-------------|
| EC2 Networking | VPC, subnets, NAT gateways, route tables, internet gateways |
| EC2 Compute | RunInstances, security groups, AMIs, EBS volumes |
| ELB / ELBv2 | API and ingress load balancers, target groups, listeners |
| IAM | Roles, instance profiles, PassRole |
| Route53 | Hosted zone management, record sets |
| S3 | Bootstrap ignition bucket, object access |

If `iam:SimulatePrincipalPolicy` is not allowed on your principal, the script automatically falls back to live read-only describe calls and warns you that write permissions cannot be verified.

### AWS Requirements

- IAM user or role with [OpenShift IPI permissions](https://docs.openshift.com/container-platform/latest/installing/installing_aws/installing-aws-account.html)
- A **Route53 public hosted zone** for your `base_domain`
- Service quotas sufficient for your chosen instance types and counts (check EC2 limits in your region)

### Red Hat Pull Secret

1. Go to https://console.redhat.com/openshift/install/pull-secret
2. Download or copy your pull secret
3. Paste it into `terraform.tfvars` as the `pull_secret` value

### Validating terraform.tfvars

Before running `terraform apply`, verify that all required values have been filled in and are valid. Run:

```bash
./scripts/validate-tfvars.sh
```

The script checks:

| Field | What is checked |
|-------|----------------|
| `cluster_name` | Non-empty, not the placeholder `my-ocp-cluster`, valid format |
| `base_domain` | Non-empty, not the placeholder `example.com` |
| `pull_secret` | Non-empty, valid JSON with an `auths` key |
| `ssh_public_key` | Non-empty, recognised SSH key type prefix |
| `aws_region` | Reported (defaults to `us-east-1` if unset) |
| `aws_profile` | Reported; warns if empty and no env vars are set |
| Cluster sizing | Summarises master and worker count + instance types |

If any required field is missing or still holds a placeholder, the script prints exactly what needs to be fixed and exits with a non-zero status, blocking `terraform apply` from proceeding.

This check also runs automatically at the start of `terraform apply` — so if you forget to run it manually, Terraform will catch it before creating any resources.

---

## Quick Start

```bash
# 1. Clone and enter the project
cd 1-ocp-on-aws

# 2. Create your variables file
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars          # Fill in required values

# 3. Make scripts executable
chmod +x scripts/*.sh

# 4. Validate terraform.tfvars is complete
./scripts/validate-tfvars.sh

# 5. Verify AWS credentials have sufficient permissions
./scripts/check-aws-permissions.sh

# 6. Initialise Terraform
terraform init

# 7. Preview the plan
terraform plan

# 8. Install the cluster (30–45 minutes)
terraform apply
```

---

## Key Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `cluster_name` | — | Cluster name (3–28 chars, lowercase) |
| `base_domain` | — | Route53 public hosted zone domain |
| `master_count` | `3` | Number of master nodes: `1` (dev) or `3` (HA) |
| `master_instance_type` | `m5.xlarge` | EC2 type for masters |
| `worker_count` | `3` | Number of worker nodes (min 2) |
| `worker_instance_type` | `m5.large` | EC2 type for workers |
| `aws_region` | `us-east-1` | AWS deployment region |
| `pull_secret` | — | Red Hat pull secret JSON |
| `ssh_public_key` | — | SSH public key for node access |
| `publish` | `External` | `External` or `Internal` |
| `network_type` | `OVNKubernetes` | CNI plugin |
| `ocp_version` | `4.16.3` | OpenShift version |

See [`variables.tf`](variables.tf) for the full list with validation rules and descriptions.

---

## Instance Type Reference

### Master Nodes
| Type | vCPU | RAM | Use case |
|------|------|-----|----------|
| `m5.xlarge` | 4 | 16 GB | Dev / small clusters |
| `m5.2xlarge` | 8 | 32 GB | Production (recommended) |
| `m6i.2xlarge` | 8 | 32 GB | Production (latest gen) |

### Worker Nodes
| Type | vCPU | RAM | Use case |
|------|------|-----|----------|
| `m5.large` | 2 | 8 GB | Dev / light workloads |
| `m5.xlarge` | 4 | 16 GB | General purpose |
| `m6i.xlarge` | 4 | 16 GB | General purpose (latest gen) |
| `c5.2xlarge` | 8 | 16 GB | Compute intensive |
| `r5.xlarge` | 4 | 32 GB | Memory intensive |
| `g4dn.xlarge` | 4 | 16 GB | GPU / AI/ML workloads |

---

## Installation Progress

The installer streams live progress to stdout. You can also tail the log in a second terminal:

```bash
tail -f clusters/<cluster-name>/.openshift_install.log
```

Typical phase timeline:

```
 0–5 min    Infrastructure provisioning (VPC, subnets, security groups)
 5–15 min   Bootstrap node starting, control plane nodes booting
15–25 min   etcd cluster forming, API server starting
25–35 min   Bootstrap complete, worker nodes joining
35–45 min   Operators installing, cluster operators becoming available
```

---

## After Installation

```bash
# Get credentials
./scripts/get-credentials.sh <cluster-name>

# Or use Terraform outputs
terraform output console_url
terraform output -raw kubeadmin_password

# Login with oc
export KUBECONFIG=clusters/<cluster-name>/auth/kubeconfig
oc get nodes
oc get clusteroperators
```

---

## Destroy

Run `terraform destroy` — the teardown is fully integrated and runs in three phases automatically:

```bash
terraform destroy
```

| Phase | What happens |
|-------|-------------|
| **1 — openshift-install destroy** | Destroys the cluster via the official installer (handles the bulk of EC2, LBs, VPC, Route53, S3, IAM) |
| **2 — Orphan cleanup** | Scans for any resources tagged `kubernetes.io/cluster/<name>=owned` that the installer missed and removes them: EC2 instances, ALB/NLB/Classic ELBs, S3 buckets, NAT gateways, Elastic IPs, security groups, VPC endpoints, subnets, route tables, internet gateways, VPCs, EBS volumes, IAM roles & instance profiles, Route53 private zones |
| **3 — Local cleanup** | Removes the `clusters/<name>/` directory (kubeconfig, credentials, logs) |

A summary is printed at the end showing how many resources were freed and any that were already gone.

---

## Project Structure

```
1-ocp-on-aws/
├── versions.tf                   # Provider version constraints
├── variables.tf                  # All input variables
├── locals.tf                     # Computed values (AZs, URLs, paths)
├── main.tf                       # Core: install-config generation + installer invocation
├── outputs.tf                    # Cluster access outputs
├── terraform.tfvars.example      # Variable template — copy to terraform.tfvars
├── templates/
│   └── install-config.yaml.tpl   # OpenShift install-config template
└── scripts/
    ├── validate-tfvars.sh        # Check terraform.tfvars is complete before applying
    ├── check-aws-permissions.sh  # Verify IAM permissions before installing
    ├── preflight.sh              # Pre-install checks (tools, AWS auth, DNS, quotas)
    └── get-credentials.sh        # Display cluster login details
```

---

## State Management

For team use, configure the S3 backend in `versions.tf`:

```hcl
backend "s3" {
  bucket         = "my-terraform-state"
  key            = "ocp-on-aws/terraform.tfstate"
  region         = "us-east-1"
  encrypt        = true
  dynamodb_table = "terraform-state-lock"
}
```

---

## Security Notes

- `terraform.tfvars` is in `.gitignore` — never commit it (contains pull secret and SSH key)
- The `clusters/` directory is in `.gitignore` — it contains `kubeconfig` and `kubeadmin-password`
- `kubeadmin` is a temporary bootstrap user — create proper identity providers and disable kubeadmin post-install
- For production, set `publish = "Internal"` and access the cluster through a VPN or bastion host
