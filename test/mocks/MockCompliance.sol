// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../../src/FCIToken_Tesis_ERC3643.sol";

/// @dev Minimal ICompliance mock. Allows toggling canTransfer and tracking call counts.
contract MockCompliance is ICompliance {

    address public tokenBound;
    bool    public transferAllowed = true;

    uint256 public bindCallCount;
    uint256 public transferredCallCount;
    uint256 public createdCallCount;
    uint256 public destroyedCallCount;

    // ---- ICompliance ----

    function bindToken(address _token) external override {
        tokenBound = _token;
        bindCallCount++;
    }

    function unbindToken(address) external override {
        tokenBound = address(0);
    }

    function isTokenBound(address _token) external view override returns (bool) {
        return tokenBound == _token;
    }

    function getTokenBound() external view override returns (address) {
        return tokenBound;
    }

    function canTransfer(address, address, uint256) external view override returns (bool) {
        return transferAllowed;
    }

    function transferred(address, address, uint256) external override {
        transferredCallCount++;
    }

    function created(address, uint256) external override {
        createdCallCount++;
    }

    function destroyed(address, uint256) external override {
        destroyedCallCount++;
    }

    // ---- Test helpers ----

    function setTransferAllowed(bool _allowed) external {
        transferAllowed = _allowed;
    }
}
