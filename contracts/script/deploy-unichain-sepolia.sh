#!/usr/bin/env bash
# Deploys Bridle to Unichain Sepolia and verifies the source on Blockscout.
# Asks for the bridle-deployer keystore password; no key is ever stored in a file.
set -euo pipefail
cd "$(dirname "$0")/.."

export STEADY_CURATOR=0x7562186636EB363D639e1328049F994BaF7aC55c
export AGENT_CURATOR=0xE970f10dc6F08fb66ef2a2A601eA7B652F4257D3
export RECKLESS_CURATOR=0x4eC233D41dD12B74076FeCFeE8a761DC2D20658C

forge script script/Deploy.s.sol \
  --rpc-url https://sepolia.unichain.org \
  --account bridle-deployer \
  --sender 0x52825Ac547d3Ed00C33488E571074e1B55577a97 \
  --broadcast \
  --verify --verifier blockscout --verifier-url https://unichain-sepolia.blockscout.com/api/
