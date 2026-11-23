// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EpochRecord} from "./interfaces/IMandate.sol";

/// @notice The curator's epoch ledger for one vault: every closed epoch scored against simply holding.
/// Inherited by BridleVault, which writes it in closeEpoch. Read by the leaderboard and the vault page.
/// A vault has exactly one curator and mandate, so this is that curator's record under that mandate.
abstract contract TrackRecord {
    uint256 public constant WAD = 1e18;

    /// @notice Excess return vs holding, compounded over all closed epochs. 1e18 = 1.0 = same as holding.
    uint256 public index = WAD;
    /// @notice Highest index a fee was charged at. Fees are only paid on index above this.
    uint256 public highWaterMark = WAD;

    EpochRecord[] internal _records;

    event EpochClosed(
        uint64 indexed epoch, uint256 navPerShare, uint256 holdPerShare, uint256 ratio, uint256 index, uint256 hwm
    );
    event FeeMinted(address indexed curator, uint256 shares, uint256 index, uint256 hwm);

    function recordCount() external view returns (uint256) {
        return _records.length;
    }

    function records() external view returns (EpochRecord[] memory) {
        return _records;
    }

    function record(uint256 i) external view returns (EpochRecord memory) {
        return _records[i];
    }
}
