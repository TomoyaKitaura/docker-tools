# image-scanner v1.0

### ECR Image Scan Example ###
# docker run --rm -v $(pwd):/work \
#   -e GITHUB_TOKEN -e AWS_ACCESS_KEY_ID \
#   -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
#   kitta0108/image-scanner -i ${Image_tag} -r ${Repository} \
#   -n ${New_Issue_Level} -t ${Type} -v ${Env}

### Dockle Example ###
# docker run --rm \
#   -v $(pwd):/work \
#   -v /var/run/docker.sock:/var/run/docker.sock \
#   -e GITHUB_TOKEN \
#   kitta0108/image-scanner -i ${Image_tag} -r ${Repository} \
#   -n ${New_Issue_Level} -t ${Type} -v ${Env} -e ${Ecr_Registry}

FROM ubuntu:20.04 AS build

RUN apt-get update
RUN apt-get install --no-install-recommends -y \
    curl=7.68.0-1ubuntu2.2 unzip=6.0-25ubuntu1 sudo=1.8.31-1ubuntu1.1 \
    ca-certificates=20190110ubuntu1.1 jq=1.6-1
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
RUN unzip awscliv2.zip
RUN ./aws/install
RUN curl -OL "https://github.com/cli/cli/releases/download/v0.11.1/gh_0.11.1_linux_amd64.deb" -o "gh_0.11.1_linux_amd64.deb"
RUN apt-get install -y --no-install-recommends ./gh_0.11.1_linux_amd64.deb

FROM ubuntu:20.04

COPY --from=build /usr/local/aws-cli /usr/local/aws-cli
COPY --from=build /usr/local/bin /usr/local/bin
COPY --from=build /usr/bin /usr/bin
COPY --from=build /usr/lib /usr/lib
COPY --from=build /etc/ssl/certs /etc/ssl/certs
COPY --from=build /etc/sudoers /etc/sudoers
COPY image_scan.sh /image_scan.sh

WORKDIR /work

ENTRYPOINT ["/image_scan.sh"]
