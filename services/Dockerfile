# syntax=docker/dockerfile:1
# check=error=true

# One image recipe for the three extracted services. Build from the repository root, because the services
# share the gems in gems/:
#
#   docker build -f services/Dockerfile --build-arg SERVICE=ai -t task-api/ai .
#   (SERVICE = ai | auth | notifications)
#
# Production image: non-root, no shell tools beyond curl for debugging, logs to stdout, read-only-root-friendly
# (only tmp/ and log/ are written).

ARG RUBY_VERSION=4.0.9
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

ARG SERVICE
RUN test -n "$SERVICE" || (echo "Pass --build-arg SERVICE=ai|auth|notifications" && exit 1)

WORKDIR /app/services/$SERVICE

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libpq5 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so" \
    RAILS_LOG_TO_STDOUT="true"

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ARG SERVICE
COPY gems /app/gems
COPY services/$SERVICE/Gemfile services/$SERVICE/Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY services/$SERVICE ./

FROM base

ARG SERVICE
LABEL org.opencontainers.image.source="https://github.com/AravindRajeshkanna/rails-task-api" \
      org.opencontainers.image.title="task-api-$SERVICE"

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /app/gems /app/gems
COPY --chown=rails:rails --from=build /app/services/$SERVICE /app/services/$SERVICE
RUN mkdir -p tmp/pids log

EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 CMD curl -fsS http://localhost:3000/up || exit 1

CMD ["./bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
