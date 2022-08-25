name: test-console

on:
  pull_request:
    branches:
      - main

jobs:
  test-console:
    runs-on: ubuntu-latest

    steps:
      - name: checkout
        uses: actions/checkout@v3

      - name: k9s
        env:
          K9S_VERSION: v0.25.3
        run: |
          curl --fail --silent --show-error -L https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_x86_64.tar.gz -o /tmp/k9s_Linux_x86_64.tar.gz
          tar -zxf /tmp/k9s_Linux_x86_64.tar.gz -C /usr/local/bin k9s
          sudo chown root /usr/local/bin/k9s
          sudo chmod 755 /usr/local/bin/k9s

      - name: just
        env:
          JUST_VERSION: 1.2.0
        run: |
          curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag ${JUST_VERSION} --to /usr/local/bin

      - name: weft
        run: |
          npm install -g @hyperledger-labs/weft

      - name: fabric
        run: |
          curl -sSL https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh | bash -s -- binary

      - name: check prereqs
        run: |
          export WORKSHOP_PATH="${PWD}"
          export PATH="${WORKSHOP_PATH}/bin:${PATH}"
          export FABRIC_CFG_PATH="${WORKSHOP_PATH}/config"

          ./check.sh

      - name: just test-console
        run: |
          just test-console