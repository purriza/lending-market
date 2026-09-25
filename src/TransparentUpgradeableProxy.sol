// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @notice Minimal EIP-1967 transparent proxy. The production markets are deployed behind this;
 *         `LendingMarket` is the implementation and all market state lives in the proxy's storage.
 *
 * @dev Calls from the proxy admin are routed to the upgrade machinery. Every other caller is
 *      delegated straight through to the implementation.
 */
contract TransparentUpgradeableProxy {
    /// @dev bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    event Upgraded(address indexed implementation);

    constructor(address implementation_, address proxyAdmin_, bytes memory initData) {
        _setSlot(_IMPLEMENTATION_SLOT, implementation_);
        _setSlot(_ADMIN_SLOT, proxyAdmin_);

        if (initData.length > 0) {
            (bool ok, bytes memory ret) = implementation_.delegatecall(initData);
            require(ok, _revertReason(ret));
        }

        emit Upgraded(implementation_);
    }

    function implementation() external view returns (address) {
        return _getSlot(_IMPLEMENTATION_SLOT);
    }

    function proxyAdmin() external view returns (address) {
        return _getSlot(_ADMIN_SLOT);
    }

    /// @notice Points the proxy at a new implementation. Storage is untouched, so the new
    ///         implementation must declare a compatible layout.
    function upgradeTo(address newImplementation) external {
        require(msg.sender == _getSlot(_ADMIN_SLOT), "not proxy admin");
        require(newImplementation.code.length > 0, "not a contract");
        _setSlot(_IMPLEMENTATION_SLOT, newImplementation);
        emit Upgraded(newImplementation);
    }

    fallback() external payable {
        address impl = _getSlot(_IMPLEMENTATION_SLOT);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}

    function _getSlot(bytes32 slot) internal view returns (address value) {
        assembly {
            value := sload(slot)
        }
    }

    function _setSlot(bytes32 slot, address value) internal {
        assembly {
            sstore(slot, value)
        }
    }

    function _revertReason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "init failed";
        assembly {
            ret := add(ret, 0x04)
        }
        return abi.decode(ret, (string));
    }
}
