# Runs the wifi-walk test suite on Linux with wdutil and sudo mocked.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends zsh \
 && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home walker
WORKDIR /app
COPY wifi-walk.sh ./
COPY tests ./tests
# Non-root so the sudo code path is exercised against the mock.
USER walker
CMD ["zsh", "tests/run.zsh"]
