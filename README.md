# AWS Emulator + Terraform in GitLab CI

A small public showcase of [AWS Emulator](https://github.com/aws/aws-emulator) (generally available 11 November 2026) used as a GitLab CI `services:` container. A pinned `hashicorp/terraform` image runs `terraform init`, `validate`, `plan`, and `apply -auto-approve` against the emulator, creates an S3 bucket and a DynamoDB table, prints the outputs, and destroys the stack.

You do not need an AWS account. Nothing in this repository talks to live AWS when the endpoint variables are set.

## What it shows

- The official Docker setup: AWS does **not** publish a prebuilt image. The [`Dockerfile`](Dockerfile) is the one from [Getting started with Docker](https://docs.aws.amazon.com/emulator/latest/userguide/getting-started-docker.html). The pipeline builds it and starts it as a service named `aws-emulator`.
- Terraform's AWS provider pointed at the emulator's single HTTPS endpoint (`https://127.0.0.1:9297` locally, `https://aws-emulator:9297` in CI), with path-style S3 and the usual "skip live AWS checks" flags.
- How credentials, the TLS certificate, and service discovery differ between a local `docker run` (documented volume mount) and GitLab `services:` (no shared filesystem).

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

In another terminal:

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

# optional: ./ci/wait-for-emulator.sh

cd terraform
terraform init
terraform apply
terraform output
terraform destroy
```

Leave `insecure_skip_tls_verify` at its default (`false`) and trust `ca.pem` via `AWS_CA_BUNDLE`.

### Option B — Linux package

On x86_64 Debian/Ubuntu, from [Getting started on Linux](https://docs.aws.amazon.com/emulator/latest/userguide/getting-started-linux.html):

```bash
curl -fsSLo aws-emulator.deb \
  https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator_amd64.deb
sudo apt-get install -y ./aws-emulator.deb
aws-emulator --telemetry off
```

Then set the same environment variables and run Terraform as above.

## How the GitLab pipeline works

Stages are **build → validate → apply**.

1. **build** builds the official Dockerfile and pushes it to the project's GitLab container registry (`$CI_REGISTRY_IMAGE/aws-emulator:$CI_COMMIT_SHA`). This step exists only because AWS does not publish a ready-made image.
2. **validate** runs `terraform fmt -check`, `init -backend=false`, and `validate` in `hashicorp/terraform:1.13.4`. It does not start the emulator.
3. **apply** starts the built image as a service (`alias: aws-emulator`), waits for `/__admin/health`, then runs `terraform init`, `validate`, `plan`, `apply -auto-approve`, `terraform output`, and `destroy` in the same job.

The apply job uses `--auth off` and `insecure_skip_tls_verify=true`. Those are CI constraints, not something to copy for a local run:

| Topic | Official local / Docker path | GitLab `services:` in this repo |
| --- | --- | --- |
| Image | You build the documented Dockerfile (`aws-emulator` is a local tag, not a published image) | Same Dockerfile, built and pushed in the `build` stage |
| Reachability | Host uses `https://127.0.0.1:9297` after `-p 127.0.0.1:9297:9297` | Job uses `https://aws-emulator:9297` on the per-job network |
| Credentials | Generated files on the bind-mounted `~/.aws/emulator` directory | `services:` cannot mount that directory into the job, so the service is started with the documented `--auth off` flag. The Terraform provider still needs *some* key pair; the job sets obvious placeholders. |
| TLS | Trust `~/.aws/emulator/9297/ca.pem` (`AWS_CA_BUNDLE`) | The certificate is issued for `127.0.0.1`, not the hostname `aws-emulator`, so the job skips TLS verification. There is no documented flag to add a SAN for the service alias. |

`--auth off` is documented for tools that cannot sign requests and for a simpler local setup. Official security guidance is to keep authentication on and to use `--auth off` only where nobody else can reach the emulator. A GitLab service is attached to a single job network and is not published to the internet; do not change the Docker publish address to `0.0.0.0` on a shared runner host.

The pipeline needs a GitLab project with Container Registry enabled (GitLab.com has this by default). Mirror or push this GitHub repository to GitLab to run it.

## Caveats

- **IAM is not evaluated like AWS.** A request AWS would deny may succeed. Do not use the emulator to test security. See [Security in AWS Emulator](https://docs.aws.amazon.com/emulator/latest/userguide/security.html).
- **State is in memory** and is deleted when the emulator stops. Each start is a clean account (`000000000000`). There is one account and no cross-account or cross-Region behaviour.
- **Unsupported operations return HTTP 501** (`NotImplemented`).
- **Fidelity varies by service.** Scores are published with each [release](https://github.com/aws/aws-emulator/releases). For AWS Emulator **v1.0.322** (11 November 2026), the published suite reported **1763 of 2814** tests passing for Amazon S3 and **1153 of 1694** for DynamoDB. Official docs also say Terraform / CloudFormation / CDK support varies; this demo sticks to control-plane calls used in the getting-started examples (`CreateBucket`, `CreateTable` with `PAY_PER_REQUEST`).
- **S3 must use path-style URLs.** The emulator does not accept virtual-hosted-style requests. This repo sets `s3_use_path_style = true`. Official docs also warn that `localhost` (rather than `127.0.0.1`) can trigger virtual-hosted-style clients.
- **Don't send real credentials or real data** to the emulator. Unset `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, and `AWS_PROFILE` before a local run.

## Repository layout

```
Dockerfile           # official AWS Dockerfile (no prebuilt image exists)
.gitlab-ci.yml       # build image, validate Terraform, apply against the service
terraform/           # AWS provider + S3 bucket + DynamoDB table
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
