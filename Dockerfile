# Official AWS Emulator Dockerfile, copied from:
# https://docs.aws.amazon.com/emulator/latest/userguide/getting-started-docker.html
#
# AWS does not publish a prebuilt image. This file installs the Linux
# package into Amazon Linux 2023 minimal. The -b 0.0.0.0 bind is required
# so Docker (and GitLab CI services) can forward port 9297.
#
# On Apple silicon or other Arm machines, replace aws-emulator-x86_64.rpm
# with aws-emulator-aarch64.rpm as documented in that guide.

FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
ADD https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator-x86_64.rpm /tmp/aws-emulator.rpm
RUN rpm -i /tmp/aws-emulator.rpm && rm /tmp/aws-emulator.rpm \
 && mkdir -p /home/emulator && chown 1000 /home/emulator
USER 1000
ENV HOME=/home/emulator
EXPOSE 9297
ENTRYPOINT ["aws-emulator", "-b", "0.0.0.0"]
