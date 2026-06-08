// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../../src/FCIToken_Tesis_ERC3643.sol";

/// @dev Minimal IIdentityRegistry mock.
///      mockRegister(user, identityAddr, country) simulates a verified KYC registration.
///      `identity(user)` returns IIdentity(identityAddr), so recoveryAddress() can compare
///      address(identity(lostWallet)) against the _investorOnchainID argument.
contract MockIdentityRegistry is IIdentityRegistry {

    mapping(address => address) private _identities; // user → on-chain identity address
    mapping(address => bool)    private _verified;
    mapping(address => uint16)  private _countries;

    // ---- Test helper ----

    function mockRegister(address user, address identityAddr, uint16 country) external {
        _identities[user] = identityAddr;
        _verified[user]   = true;
        _countries[user]  = country;
    }

    // ---- IIdentityRegistry ----

    function identityStorage() external pure override returns (IIdentityRegistryStorage) {
        return IIdentityRegistryStorage(address(0));
    }

    function issuersRegistry() external pure override returns (ITrustedIssuersRegistry) {
        return ITrustedIssuersRegistry(address(0));
    }

    function topicsRegistry() external pure override returns (IClaimTopicsRegistry) {
        return IClaimTopicsRegistry(address(0));
    }

    function setIdentityRegistryStorage(address) external override {}
    function setClaimTopicsRegistry(address) external override {}
    function setTrustedIssuersRegistry(address) external override {}

    function registerIdentity(address user, IIdentity _identity, uint16 country) external override {
        _identities[user] = address(_identity);
        _verified[user]   = true;
        _countries[user]  = country;
    }

    function deleteIdentity(address user) external override {
        _identities[user] = address(0);
        _verified[user]   = false;
    }

    function updateCountry(address user, uint16 country) external override {
        _countries[user] = country;
    }

    function updateIdentity(address user, IIdentity _identity) external override {
        _identities[user] = address(_identity);
    }

    function batchRegisterIdentity(
        address[] calldata users,
        IIdentity[] calldata identities,
        uint16[] calldata countries
    ) external override {
        for (uint256 i = 0; i < users.length; i++) {
            _identities[users[i]] = address(identities[i]);
            _verified[users[i]]   = true;
            _countries[users[i]]  = countries[i];
        }
    }

    function contains(address user) external view override returns (bool) {
        return _identities[user] != address(0);
    }

    function isVerified(address user) external view override returns (bool) {
        return _verified[user];
    }

    function identity(address user) external view override returns (IIdentity) {
        return IIdentity(_identities[user]);
    }

    function investorCountry(address user) external view override returns (uint16) {
        return _countries[user];
    }
}
