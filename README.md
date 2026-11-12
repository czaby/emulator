# AWS Emulator as a Terraform verification gate

A public showcase of [AWS Emulator](https://github.com/aws/aws-emulator) (generally available 11 November 2026) used as a GitLab CI `services:` container. The Terraform in [`terraform/`](terraform/) is ordinary AWS code: the same configuration can be applied to real AWS. The pipeline first applies it against the emulator as a verification step, then (optionally, by hand) to AWS.

You do not need an AWS account to run the emulator path. Nothing in this repository talks to live AWS when the emulator override, compatibility proxy, and endpoint variables are set.

## What it shows

- The official Docker setup: AWS does **not** publish a prebuilt image. The [`Dockerfile`](Dockerfile) is the one from [Getting started with Docker](https://docs.aws.amazon.com/emulator/latest/userguide/getting-started-docker.html). The pipeline builds it with **Kaniko** (no Docker-in-Docker) and starts it as a service named `aws-emulator`.
- How to keep `providers.tf` as a normal AWS provider block (`region` only). Everything emulator-specific (custom endpoints, `skip_*` flags, path-style S3, insecure TLS) is injected at job time by copying [`ci/emulator_override.tf`](ci/emulator_override.tf) into `terraform/emulator_override.tf`. Terraform's [`*_override.tf` merge semantics](https://developer.hashicorp.com/terraform/language/files/override) then merge those arguments into the existing provider block.
- A small but realistic stack: S3, a VPC with two subnets, an Aurora MySQL Serverless v2 cluster and instance, an ECS cluster plus a Fargate task and service, and an SNS topic with an SQS subscription.
- A CI-only compatibility proxy ([`ci/emulator_compat_proxy.py`](ci/emulator_compat_proxy.py)) that rewrites two request shapes the emulator rejects but real AWS accepts, so `terraform apply` and `terraform destroy` can run to completion without changing the AWS-normal Terraform.
- A manual `deploy:aws` job that runs the **unchanged** `terraform/` directory against real AWS with real credentials (no override, no proxy).

## How the emulator override works

`terraform/providers.tf` is only this:

```hcl
provider "aws" {
  region = var.aws_region
}
```

`ci/emulator_override.tf` contains a second `provider "aws"` block with `skip_credentials_validation`, `skip_requesting_account_id`, `skip_metadata_api_check`, `skip_region_validation`, `s3_use_path_style`, `insecure`, and an `endpoints` block that points every service used in this demo at `var.aws_endpoint`.

Terraform does **not** treat that as a second provider. Because the file is named `*_override.tf`, it merges into the existing `provider "aws"` block: top-level arguments in the override replace same-named arguments, and the `endpoints` nested block is added as a whole. `region` from `providers.tf` is kept. This was verified with `terraform show -json` on a plan: `configuration.provider_config.aws.expressions` contained both `region = var.aws_region` and all of the override arguments.

Override files cannot declare **new** variables. They can only override variables that already exist in a primary file. That is why `aws_endpoint` and `insecure_skip_tls_verify` are declared in `terraform/variables.tf` (with defaults). They are unused unless the override file has been copied in. The apply job sets them with `TF_VAR_aws_endpoint` and `TF_VAR_insecure_skip_tls_verify`.

The copy is gitignored under `terraform/` (`*_override.tf`, with an exception for `ci/emulator_override.tf`). The `deploy:aws` job refuses to run if that copy is present.

## Compatibility proxy (CI / local no-auth only)

Two Terraform AWS provider behaviours hit emulator API mismatches. Neither can be fixed by a provider version pin or a Terraform override, and both are required for a clean apply and destroy of this stack. The apply job therefore starts [`ci/emulator_compat_proxy.py`](ci/emulator_compat_proxy.py) and points Terraform at it (`https://127.0.0.1:9298`). The proxy forwards every request to the emulator and rewrites only these two shapes. It does not invent resource results.

Use it only with `--auth off`. Rewriting the body would invalidate SigV4.

### 1. `DescribeGlobalClusters` filter `db-cluster-id`

After `CreateDBCluster`, `aws_rds_cluster` is read. For `engine_mode` `global` or `provisioned` (Serverless v2 uses `provisioned`), hashicorp/aws **5.100.0** (latest 5.x) and **6.73.0** (latest 6.x as of this writing) both call `findGlobalClusterByDBClusterARN`, which sends `DescribeGlobalClusters` with `Filters.Name=db-cluster-id`. The only errors those versions ignore are `NotFound` and `InvalidParameterValue` containing `Access Denied to API Version: APIGlobalDatabases` (regions/partitions without Aurora Global Databases).

Sources:

- Provider 5.100.0 read path: [`internal/service/rds/cluster.go`](https://github.com/hashicorp/terraform-provider-aws/blob/v5.100.0/internal/service/rds/cluster.go) (`resourceClusterRead`, around the `findGlobalClusterByDBClusterARN` call)
- Provider 5.100.0 lookup: [`internal/service/rds/global_cluster.go`](https://github.com/hashicorp/terraform-provider-aws/blob/v5.100.0/internal/service/rds/global_cluster.go) (`findGlobalClusterByDBClusterARN`)
- Same logic is still in [v6.73.0 `cluster.go`](https://github.com/hashicorp/terraform-provider-aws/blob/v6.73.0/internal/service/rds/cluster.go) and [`global_cluster.go`](https://github.com/hashicorp/terraform-provider-aws/blob/v6.73.0/internal/service/rds/global_cluster.go)
- Why every provisioned cluster is looked up: [hashicorp/terraform-provider-aws#12524](https://github.com/hashicorp/terraform-provider-aws/issues/12524) (since 2.59.0, because Aurora reports `engine_mode=provisioned` for global-cluster members)
- Current official AWS docs: [DescribeGlobalClusters](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_DescribeGlobalClusters.html) — “Currently, the only supported filter is `region`.” The emulator follows that and returns HTTP 400 `InvalidParameterValue: unrecognized filter name: db-cluster-id; the only supported filter is region`. Real AWS still accepts the undocumented filter (otherwise the provider would fail against AWS).
- [aws/aws-emulator releases](https://github.com/aws/aws-emulator/releases): **v1.0.322** (11 November 2026) is the current release. No later build adds this filter. There is no emulator issue for this call yet.
- LocalStack/moto: [getmoto/moto#6151](https://github.com/getmoto/moto/issues/6151) discussed missing global-cluster APIs; not a fix here.

What was tried and rejected:

- Pinning an older or newer official hashicorp/aws: every version that supports Aurora Serverless v2 also makes this call for `provisioned` clusters, and 5.100.0 / 6.73.0 still error on the emulator's 400.
- Provider settings or a `*_override.tf` trick: there is no flag to skip the global-cluster lookup.
- A newer emulator package: 1.0.322 is current; the official Dockerfile already installs `LTS/latest`.

The proxy strips the `db-cluster-id` filter and forwards the request. `DescribeGlobalClusters` with no filter (or `Name=region`) succeeds on the emulator and returns an empty list. The provider treats that as `NotFound` and continues. The cluster itself is created and deleted by the real emulator APIs (`CreateDBCluster`, `CreateDBInstance`, `DeleteDBInstance`, `DeleteDBCluster`).

### 2. Default security-group egress revoke

On create, the AWS provider always revokes the default IPv4 egress rule by sending `RevokeSecurityGroupEgress` with `IpProtocol=-1`, `FromPort=0`, `ToPort=0`. It does **not** ignore `InvalidPermission.NotFound` for that IPv4 revoke (it does ignore it for the IPv6 revoke). See [`vpc_security_group.go` in v5.100.0](https://github.com/hashicorp/terraform-provider-aws/blob/v5.100.0/internal/service/ec2/vpc_security_group.go) and the same in [v6.73.0](https://github.com/hashicorp/terraform-provider-aws/blob/v6.73.0/internal/service/ec2/vpc_security_group.go).

The emulator **does** create a default allow-all egress rule, but stores it with no ports. It compares ports exactly, so a request with `FromPort=0, ToPort=0` returns `InvalidPermission.NotFound`. A request that omits the ports succeeds. This is [aws/aws-emulator#46](https://github.com/aws/aws-emulator/issues/46) (open, 12 November 2026). The same mismatch was seen years ago with moto ([getmoto/moto#2551](https://github.com/spulec/moto/issues/2551)). No released emulator or provider version fixes it.

The proxy drops `FromPort`/`ToPort` on `IpProtocol=-1` members of `RevokeSecurityGroupEgress` and forwards the request. The IPv6 revoke (no such default rule) still returns `NotFound`; the provider already ignores that.

## How the GitLab pipeline works

Stages are **build → validate → apply → deploy**.

1. **build** (`build:emulator-image`) builds the official Dockerfile with Kaniko (`gcr.io/kaniko-project/executor:debug`) and pushes `$CI_REGISTRY_IMAGE/aws-emulator:$CI_COMMIT_SHA` (and `:latest`) to the project's GitLab container registry. There is no Docker-in-Docker. This step exists only because AWS does not publish a ready-made image.
2. **validate** (`validate:terraform`) runs `terraform fmt -check`, `init -backend=false`, and `validate` in `hashicorp/terraform:1.13.4`. It does **not** copy the override, does **not** start the emulator or the proxy, and is the same static check you would run before applying to AWS.
3. **apply** (`apply:emulator`) is the verification gate. It starts the built image as a service (`alias: aws-emulator`), waits for `/__admin/health`, starts the compatibility proxy, copies the override file, then runs `terraform init`, `validate`, `plan`, `apply -auto-approve`, `terraform output`, and `destroy` in the same job. If apply fails, destroy still runs and the job exits with apply's status.
4. **deploy** (`deploy:aws`) is `when: manual` on the default branch. It does not copy the override and does not use the proxy. It `needs` `validate:terraform` and, optionally, `apply:emulator`. Configure real AWS credentials as protected GitLab CI/CD variables, or use an IAM identity on the runner. This job **creates billable AWS resources** (VPC, Aurora Serverless v2, Fargate, and so on) and does not destroy them. Review the plan and the unique-name variables (especially the S3 bucket) before you run it.

The apply job uses `--auth off` and `insecure_skip_tls_verify=true`. Those are CI constraints, not something to copy for a local run that can use the generated certificate:

| Topic | Official local / Docker path | GitLab `services:` in this repo |
| --- | --- | --- |
| Image | You build the documented Dockerfile (`aws-emulator` is a local tag, not a published image) | Same Dockerfile, built and pushed with Kaniko in the `build` stage |
| Reachability | Host uses `https://127.0.0.1:9297` after `-p 127.0.0.1:9297:9297` | Job uses `https://aws-emulator:9297` on the per-job network, then a localhost compatibility proxy |
| Credentials | Generated files on the bind-mounted `~/.aws/emulator` directory | `services:` cannot mount that directory into the job, so the service is started with the documented `--auth off` flag. The Terraform provider still needs *some* key pair; the job sets obvious placeholders. |
| TLS | Trust `~/.aws/emulator/9297/ca.pem` (`AWS_CA_BUNDLE`), leave `insecure_skip_tls_verify=false` | The certificate is issued for `127.0.0.1`, not the hostname `aws-emulator`, so the job skips TLS verification. There is no documented flag to add a SAN for the service alias. |
| Provider config | Copy `ci/emulator_override.tf` into `terraform/` before `terraform init` | The apply job does that copy; `deploy:aws` does not |
| Compatibility proxy | Optional; required for a clean apply/destroy of security groups and Aurora (and only with `--auth off`) | Started in the apply job; Terraform is pointed at `https://127.0.0.1:9298` |

`--auth off` is documented for tools that cannot sign requests and for a simpler local setup. Official security guidance is to keep authentication on and to use `--auth off` only where nobody else can reach the emulator. A GitLab service is attached to a single job network and is not published to the internet; do not change the Docker publish address to `0.0.0.0` on a shared runner host.

The pipeline needs a GitLab project with Container Registry enabled (GitLab.com has this by default). Mirror or push this GitHub repository to GitLab to run it.

## Results against the emulator

Tested locally against **aws-emulator 1.0.322** (12 November 2026) in the same no-auth mode the CI job uses: `--auth off --telemetry off`, placeholder keys, `ci/emulator_override.tf` copied into `terraform/`, compatibility proxy on `https://127.0.0.1:9298`, `TF_VAR_insecure_skip_tls_verify=true`, Terraform 1.13.4, hashicorp/aws 5.100.0, hashicorp/random 3.9.1.

A clean `terraform apply` and `terraform destroy` both completed:

```
Apply complete! Resources: 25 added, 0 changed, 0 destroyed.
Destroy complete! Resources: 25 destroyed.
```

| Resource | Result | Detail |
| --- | --- | --- |
| `random_password.db` | created and destroyed | Local; no AWS API. |
| `aws_s3_bucket.demo` | created and destroyed | |
| `aws_sns_topic.demo` | created and destroyed | |
| `aws_sqs_queue.demo` | created and destroyed | About 25s to create. |
| `aws_sns_topic_subscription.sqs` | created and destroyed | |
| `aws_sqs_queue_policy.demo` | created and destroyed | About 25s to create. |
| `aws_iam_role.ecs_execution` | created and destroyed | |
| `aws_iam_role_policy_attachment.ecs_execution` | created and destroyed | |
| `aws_ecs_cluster.demo` | created and destroyed | About 10s to create. |
| `aws_ecs_task_definition.demo` | created and destroyed | Fargate, `awsvpc`, 256 CPU / 512 memory, nginx image. |
| `aws_ecs_service.demo` | created and destroyed | ARN `arn:aws:ecs:us-east-1:000000000000:service/emulator-demo/emulator-demo-nginx`. |
| `aws_vpc.demo` | created and destroyed | About 10s to create. |
| `aws_internet_gateway.demo` | created and destroyed | |
| `aws_subnet.demo[0]`, `aws_subnet.demo[1]` | created and destroyed | About 10s each to create. |
| `aws_route_table.demo` | created and destroyed | |
| `aws_route_table_association.demo[0]`, `[1]` | created and destroyed | |
| `aws_db_subnet_group.demo` | created and destroyed | |
| `aws_security_group.db`, `aws_security_group.ecs` | created and destroyed | Succeeds when the compatibility proxy drops `FromPort`/`ToPort` on the default IPv4 egress revoke ([aws/aws-emulator#46](https://github.com/aws/aws-emulator/issues/46)). Without the proxy, create fails with `RevokeSecurityGroupEgress` / `InvalidPermission.NotFound`. |
| `aws_vpc_security_group_ingress_rule.db_mysql`, `ecs_http` | created and destroyed | |
| `aws_rds_cluster.demo` | created and destroyed | Aurora MySQL Serverless v2 (`engine = aurora-mysql`, `engine_mode = provisioned`, scaling 0.5–1), about 30s to create. Writer endpoint reported as `127.0.0.1`. Succeeds when the proxy strips the `db-cluster-id` filter from `DescribeGlobalClusters`. Without the proxy, Terraform reports failure after the cluster has been created, taints the resource, and `destroy` cannot refresh it. |
| `aws_rds_cluster_instance.demo` | created and destroyed | `instance_class = db.serverless`, about 31s to create. Reached because the cluster resource now completes its read. |

The proxy log showed the two expected rewrites (`RevokeSecurityGroupEgress:drop-ports-on-protocol--1` and `DescribeGlobalClusters:strip-db-cluster-id`). The IPv6 default-egress revoke still returns `InvalidPermission.NotFound` after the port rewrite (the emulator never added an IPv6 default rule); the provider already ignores that error.

## How to run it locally

### Option A — Docker (the path this pipeline uses)

You need Docker and Terraform 1.6 or later (the pipeline pins `hashicorp/terraform:1.13.4`).

```bash
docker build -t aws-emulator .

mkdir -p ~/.aws/emulator
PORT=9297
docker run --rm --memory=2g --memory-swap=2g -p 127.0.0.1:$PORT:$PORT \
  --user "$(id -u):$(id -g)" \
  -e HOME="$HOME" -v "$HOME/.aws/emulator:$HOME/.aws/emulator" \
  aws-emulator -p $PORT --telemetry off
```

`--user` is recommended on Linux so the generated files are owned by you. The `-v` mount is how a client on the host reads the credentials and `ca.pem`. On Apple silicon, use `aws-emulator-aarch64.rpm` in the Dockerfile as the official guide describes.

A fully clean apply/destroy of this stack needs the compatibility proxy, and the proxy needs `--auth off` (it rewrites request bodies). CI-style local run:

```bash
# Start the emulator with: aws-emulator --telemetry off --auth off
# Then:
python3 ci/emulator_compat_proxy.py --listen 127.0.0.1:9298 --upstream https://127.0.0.1:9297

export AWS_ACCESS_KEY_ID=EMULATORPLACEHOLDER
export AWS_SECRET_ACCESS_KEY=emulator-placeholder-secret-not-used
export AWS_ENDPOINT_URL=https://127.0.0.1:9298
export AWS_EC2_METADATA_DISABLED=true
export AWS_DISABLE_HOST_PREFIX_INJECTION=true
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export TF_VAR_aws_endpoint=https://127.0.0.1:9298
export TF_VAR_insecure_skip_tls_verify=true
unset AWS_PROFILE AWS_SESSION_TOKEN AWS_CA_BUNDLE AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE

# optional: INSECURE=1 AWS_ENDPOINT_URL=https://127.0.0.1:9297 ./ci/wait-for-emulator.sh

cp ci/emulator_override.tf terraform/emulator_override.tf
cd terraform
terraform init
terraform apply
terraform output
terraform destroy
rm -f emulator_override.tf
```

If you start the emulator with default auth (recommended when you are not exercising the full stack), use the generated files, leave `insecure_skip_tls_verify` false, and talk to `https://127.0.0.1:9297` directly — but do not expect `aws_security_group` or `aws_rds_cluster` to apply cleanly until the emulator issues above are fixed.

### Option B — Linux package

On x86_64 Debian/Ubuntu, from [Getting started on Linux](https://docs.aws.amazon.com/emulator/latest/userguide/getting-started-linux.html):

```bash
curl -fsSLo aws-emulator.deb \
  https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator_amd64.deb
sudo apt-get install -y ./aws-emulator.deb
aws-emulator --telemetry off --auth off
```

Then start the proxy, set the same environment variables, copy the override, and run Terraform as above.

### Validate the plain AWS configuration (no emulator)

```bash
# no override file in terraform/
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
```

## How the emulator works (from the official docs)

- It serves HTTPS on port **9297** by default. The process listens on `127.0.0.1` unless you pass `-b 0.0.0.0`. The official Dockerfile uses `-b 0.0.0.0` so Docker can forward the port; you should still publish it on `127.0.0.1` on the host (`-p 127.0.0.1:9297:9297`), not on all interfaces.
- Each start generates a new access key (IDs start with `EMULATOR`), a config file, and a certificate, and writes them under `~/.aws/emulator/9297/` (`emulator_credentials`, `config`, `ca.pem`, `truststore.p12`). The keys work only for that run. The emulator rejects requests signed with any other keys when authentication is on (the default).
- Point the AWS CLI or SDK at it with:

  ```bash
  export AWS_ENDPOINT_URL=https://127.0.0.1:9297
  export AWS_SHARED_CREDENTIALS_FILE=~/.aws/emulator/9297/emulator_credentials
  export AWS_CONFIG_FILE=~/.aws/emulator/9297/config
  export AWS_CA_BUNDLE=~/.aws/emulator/9297/ca.pem
  export AWS_EC2_METADATA_DISABLED=true
  export AWS_DISABLE_HOST_PREFIX_INJECTION=true
  export AWS_REGION=us-east-1
  export AWS_DEFAULT_REGION=us-east-1
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
  ```

- Wait for `GET https://127.0.0.1:9297/__admin/health` (body `ok`). Confirm with `aws sts get-caller-identity`: the emulator account is `000000000000`.
- Telemetry is on by default. This repo starts the emulator with `--telemetry off`.

## Caveats

- **IAM is not evaluated like AWS.** A request AWS would deny may succeed. Do not use the emulator to test security. See [Security in AWS Emulator](https://docs.aws.amazon.com/emulator/latest/userguide/security.html).
- **State is in memory** and is deleted when the emulator stops. Each start is a clean account (`000000000000`). There is one account and no cross-account or cross-Region behaviour.
- **Unsupported operations return HTTP 501** (`NotImplemented`). The two gaps this proxy works around are HTTP 400s from implemented-but-stricter APIs, not 501s.
- **Fidelity varies by service.** Scores are published with each [release](https://github.com/aws/aws-emulator/releases). Official docs also say Terraform / CloudFormation / CDK support varies.
- **S3 must use path-style URLs.** The emulator does not accept virtual-hosted-style requests. The override file sets `s3_use_path_style = true`. Official docs also warn that `localhost` (rather than `127.0.0.1`) can trigger virtual-hosted-style clients.
- **Don't send real credentials or real data** to the emulator. Unset `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, and `AWS_PROFILE` before a local authenticated run, or use only the placeholder keys in `--auth off` mode.
- **`deploy:aws` talks to real AWS** and will incur cost. Change the S3 bucket name; it must be globally unique.

## Repository layout

```
Dockerfile                    # official AWS Dockerfile (no prebuilt image exists)
.gitlab-ci.yml                # Kaniko build, validate (plain AWS), apply (emulator), manual deploy-aws
terraform/                    # ordinary AWS Terraform (S3, VPC, Aurora, ECS, SNS)
ci/emulator_override.tf       # copied into terraform/ only for emulator runs
ci/emulator_compat_proxy.py   # CI/local no-auth proxy; rewrites two request shapes
ci/wait-for-emulator.sh
```

## Sources

- [AWS News Blog: Test your applications against AWS locally with AWS Emulator](https://aws.amazon.com/blogs/aws/test-your-applications-against-aws-locally-with-aws-emulator/)
- [AWS Emulator GitHub repository](https://github.com/aws/aws-emulator)
- [AWS Emulator User Guide](https://docs.aws.amazon.com/emulator/latest/userguide/what-is-service.html)
- [Getting started with Docker](https://docs.aws.amazon.com/emulator/latest/userguide/getting-started-docker.html)
- [Pointing your AWS SDK at AWS Emulator](https://docs.aws.amazon.com/emulator/latest/userguide/point-sdk-to-emulator.html)
- [Command reference](https://docs.aws.amazon.com/emulator/latest/userguide/cli-reference.html) (bind, port, auth, telemetry, health, generated files)
- [Fidelity](https://docs.aws.amazon.com/emulator/latest/userguide/fidelity.html) and [releases / scores](https://github.com/aws/aws-emulator/releases)
- [What's New, 11 November 2026](https://aws.amazon.com/about-aws/whats-new/2026/11/aws-emulator-now-available/)
- [Terraform override files](https://developer.hashicorp.com/terraform/language/files/override)
- [DescribeGlobalClusters API](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_DescribeGlobalClusters.html)
- [hashicorp/terraform-provider-aws#12524](https://github.com/hashicorp/terraform-provider-aws/issues/12524)
- [aws/aws-emulator#46](https://github.com/aws/aws-emulator/issues/46)
