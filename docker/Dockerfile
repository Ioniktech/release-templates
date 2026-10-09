FROM alpine:3.21

# Supplied by the workflows; see ../AGENTS.md for the build-arg contract.
ARG BUILD_DATE
ARG BUILD_NUMBER
ARG RELEASE
ARG VERSION

LABEL org.opencontainers.image.title="hello-world" \
      org.opencontainers.image.description="Hello-world image used to exercise the Docker Hub release pipeline" \
      org.opencontainers.image.source="https://github.com/Ioniktech/release-templates" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="${RELEASE}" \
      org.opencontainers.image.revision="${VERSION}" \
      io.ioniktech.build-number="${BUILD_NUMBER}"

# Baked in so `docker run` can report which release it came from.
ENV RELEASE=${RELEASE}

# A copy of the root LICENSE: the build context cannot reach outside this
# directory, and the image declares Apache-2.0 above, so it carries the text.
COPY LICENSE /usr/share/licenses/hello-world/LICENSE

COPY hello.sh /usr/local/bin/hello
RUN chmod 0755 /usr/local/bin/hello

RUN adduser -D -u 10001 hello
USER hello

ENTRYPOINT ["/usr/local/bin/hello"]
