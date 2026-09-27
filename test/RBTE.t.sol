// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RBTE} from "../src/RBTE.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract RBTETest is Test {
    RBTE internal token;
    address internal constant ALICE = address(0xa11ce);
    address internal constant BOB = address(0xb0b);

    function setUp() public {
        token = new RBTE();
    }

    function test_metadataAndFactoryAllocation() public view {
        assertEq(token.name(), "Rebate");
        assertEq(token.symbol(), "RBTE");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testFuzz_transfersConserveSupply(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        vm.prank(ALICE);
        token.transfer(ALICE, amount);
        assertEq(token.balanceOf(ALICE), amount);
    }

    function test_allowanceAndTransferFrom() public {
        token.approve(ALICE, 20 ether);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 7 ether));
        assertEq(token.allowance(address(this), ALICE), 13 ether);
        assertEq(token.balanceOf(BOB), 7 ether);
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1 ether);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
    }

    function test_invalidTransfersAndAllowancesRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
    }

    function test_noAdminMintBurnOrUpgradeSurface() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "burn(uint256)",
            "owner()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, uint256(1));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(ALICE);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(ALICE), 0);
    }
}
