FROM rust:alpine3.10 as builder

ENV EXA_VERSION=v0.9.0

RUN apk update
RUN apk add git
RUN git clone --depth=1 -b ${EXA_VERSION} https://github.com/ogham/exa
RUN cargo install --no-default-features --path /exa

FROM rust:alpine3.10

COPY --from=builder /usr/local/cargo/bin/exa /usr/local/bin/exa

WORKDIR /work

CMD ["exa"]
