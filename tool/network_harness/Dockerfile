FROM dart:3.13.3@sha256:7e57e61d97813dc57dd0801656ff4d5c5efafa47bae563a681571543ad30f199
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 ethtool \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
COPY pubspec.yaml ./
RUN dart pub get
COPY lib ./lib
COPY player_network_harness.dart ./tool/player_network_harness.dart
ENTRYPOINT ["dart", "run", "tool/player_network_harness.dart"]
