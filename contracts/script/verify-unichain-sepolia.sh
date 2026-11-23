#!/usr/bin/env bash
# Publishes source on Blockscout for the Unichain Sepolia deployment. Sends no transactions, needs no key.
# Blockscout rate-limits, so it pauses between contracts; rerun later if one still hits "Too many requests".
set -uo pipefail
cd "$(dirname "$0")/.."

verify() { # address contract-path:Name
  echo "== $2 at $1"
  forge verify-contract "$1" "$2" --guess-constructor-args \
    --rpc-url https://sepolia.unichain.org \
    --verifier blockscout --verifier-url https://unichain-sepolia.blockscout.com/api/ \
    --watch --retries 10 --delay 20 || echo "!! $2 not verified yet"
  sleep 20
}

verify 0x518a298ffACd7703c45C397823DDfD4C158ABBEF script/DemoContracts.sol:TestToken   # tUSDC
verify 0x3353E250A2aF035e4AfC86615186d6CDf9f16E9e script/DemoContracts.sol:DemoFeed
verify 0x38dE68042435098bE0c8296a2F6FC0b3c22F7372 src/BridleVault.sol:BridleVault     # Steady
verify 0x5eFD71dB1A7dA5e3314Be8112174a76c26b20495 src/BridleVault.sol:BridleVault     # Agent
verify 0xd0F560B18D535acc5C3F1ED6620de35eE0D8760F src/BridleVault.sol:BridleVault     # Reckless
# already verified at deploy time: BridleHook 0x5a2017AA16Cde9e88f5e8Ed0928FFBcff1eA6880, tWETH 0x01163d86A5A3a818879f116e3cd66d5aff8aC855
