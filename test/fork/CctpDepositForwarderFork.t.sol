// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CctpDepositForwarder} from "../../src/rails/cctp/CctpDepositForwarder.sol";
import {CctpDepositForwarderFactory} from "../../src/rails/cctp/CctpDepositForwarderFactory.sol";

/// @notice Opt-in fork test against the REAL Base Sepolia TokenMessengerV2.
///   BASE_SEPOLIA_FORK=1 forge test --match-path test/fork/CctpDepositForwarderFork.t.sol -vv
///   Optional: BASE_SEPOLIA_RPC (default https://sepolia.base.org).
contract CctpDepositForwarderForkTest is Test {
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant TOKEN_MESSENGER_V2 = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;
    uint32 constant DOMAIN_ARC = 26;
    uint32 constant DOMAIN_AVALANCHE = 1;

    bytes32 constant DEPOSIT_FOR_BURN_TOPIC =
        keccak256("DepositForBurn(address,uint256,address,bytes32,uint32,bytes32,bytes32,uint256,uint32,bytes)");

    bytes32 constant RECIPIENT = bytes32(uint256(uint160(0xA02C4C249f14A69BF1D4aDca093c625ef066c296)));
    bytes32 constant COMMITMENT = keccak256("bufi.forwarder.fork-test");

    CctpDepositForwarderFactory internal factory;
    bool internal enabled;

    function setUp() public {
        enabled = vm.envOr("BASE_SEPOLIA_FORK", uint256(0)) == 1;
        vm.skip(!enabled);
        if (!enabled) return;
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC", string("https://sepolia.base.org")));
        assertEq(block.chainid, 84532, "not Base Sepolia");
        CctpDepositForwarder impl = new CctpDepositForwarder();
        factory = new CctpDepositForwarderFactory(address(impl), USDC, TOKEN_MESSENGER_V2);
    }

    function _flushAndCheck(uint32 domain, bytes32 caller_, uint16 bps, bool fast, uint256 amount) internal {
        address predicted = factory.predict(domain, RECIPIENT, caller_, bps, COMMITMENT);
        assertEq(predicted.code.length, 0, "must be counterfactual");
        deal(USDC, predicted, amount); // funded BEFORE deploy
        assertEq(IERC20(USDC).balanceOf(predicted), amount);

        uint256 supplyBefore = IERC20(USDC).totalSupply();
        vm.recordLogs();
        vm.prank(address(0xB0B)); // any caller
        (address fwd, uint256 flushed, uint256 maxFee) =
            factory.deployAndFlush(domain, RECIPIENT, caller_, bps, COMMITMENT, fast);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(fwd, predicted);
        assertEq(flushed, amount);
        assertEq(IERC20(USDC).balanceOf(fwd), 0, "forwarder emptied");
        assertEq(IERC20(USDC).allowance(fwd, TOKEN_MESSENGER_V2), 0, "allowance reset");
        assertEq(IERC20(USDC).totalSupply(), supplyBefore - amount, "USDC actually burned");

        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != TOKEN_MESSENGER_V2 || logs[i].topics[0] != DEPOSIT_FOR_BURN_TOPIC) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), USDC, "burnToken");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), fwd, "depositor");
            assertEq(uint32(uint256(logs[i].topics[3])), fast ? 1000 : 2000, "minFinalityThreshold");
            (
                uint256 amt,
                bytes32 mintRecipient,
                uint32 destinationDomain,, // destinationTokenMessenger
                bytes32 destinationCaller,
                uint256 fee,
                bytes memory hookData
            ) = abi.decode(logs[i].data, (uint256, bytes32, uint32, bytes32, bytes32, uint256, bytes));
            assertEq(amt, amount, "amount");
            assertEq(mintRecipient, RECIPIENT, "mintRecipient");
            assertEq(destinationDomain, domain, "destinationDomain");
            assertEq(destinationCaller, caller_, "destinationCaller");
            assertEq(fee, maxFee, "maxFee");
            assertEq(fee, fast ? (amount * bps + 9_999) / 10_000 : 0, "maxFee formula");
            assertEq(
                keccak256(hookData),
                keccak256(abi.encode(keccak256("bufi.cctp-deposit-forwarder.v1"), COMMITMENT)),
                "hookData"
            );
        }
        assertTrue(found, "DepositForBurn not emitted by the real TokenMessengerV2");
    }

    function test_fork_fastToArc() public {
        if (!enabled) return;
        _flushAndCheck(DOMAIN_ARC, bytes32(0), 10, true, 1_000_000);
    }

    function test_fork_standardToAvalanche() public {
        if (!enabled) return;
        _flushAndCheck(DOMAIN_AVALANCHE, bytes32(uint256(0xCA11E5)), 10, false, 25_000_000);
    }

    function test_fork_secondDepositFlushedAgain() public {
        if (!enabled) return;
        _flushAndCheck(DOMAIN_ARC, bytes32(0), 10, true, 3_000_000);
        address fwd = factory.predict(DOMAIN_ARC, RECIPIENT, bytes32(0), 10, COMMITMENT);
        deal(USDC, fwd, 7_000_000);
        (uint256 amount, uint256 fee) = CctpDepositForwarder(fwd).flush(false);
        assertEq(amount, 7_000_000);
        assertEq(fee, 0);
        assertEq(IERC20(USDC).balanceOf(fwd), 0);
    }

    /// @dev Pins that the live TokenMessengerV2 has no source-side minimum fee: a fast burn whose
    ///      maxFee is below Circle's published fast fee (here 0, and 1 unit) is accepted at source
    ///      (attestation timing is then Circle's choice; expected standard finality). If Circle upgrades the proxy to enforce a
    ///      minimum, this test fails first.
    function test_fork_fastBelowCircleMinimum_acceptedAtSource() public {
        if (!enabled) return;
        _flushAndCheck(DOMAIN_ARC, bytes32(0), 0, true, 2_000_000);
        address oneUnit = factory.predict(DOMAIN_AVALANCHE, RECIPIENT, bytes32(0), 100, COMMITMENT);
        deal(USDC, oneUnit, 1);
        (, uint256 amount, uint256 fee) =
            factory.deployAndFlush(DOMAIN_AVALANCHE, RECIPIENT, bytes32(0), 100, COMMITMENT, true);
        assertEq(amount, 1);
        assertEq(fee, 0);
    }
}
