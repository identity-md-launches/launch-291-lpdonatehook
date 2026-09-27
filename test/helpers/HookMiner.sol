// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPDonateHook} from "../../src/LPDonateHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

library HookMiner {
    function find(address deployer, IPoolManager manager, uint160 flags)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes32 codeHash = keccak256(abi.encodePacked(type(LPDonateHook).creationCode, abi.encode(manager)));
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, codeHash))))
            );
            if (uint160(predicted) & 0x3fff == flags) return (salt, predicted);
        }
        revert("salt search exhausted");
    }
}
