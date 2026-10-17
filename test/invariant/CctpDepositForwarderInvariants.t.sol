// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test, StdInvariant} from "forge-std/Test.sol";

import {CctpDepositForwarder} from "../../src/rails/cctp/CctpDepositForwarder.sol";
import {CctpDepositForwarderFactory} from "../../src/rails/cctp/CctpDepositForwarderFactory.sol";
import {MockForwarderUSDC as MockUSDC} from "../mocks/MockForwarderUSDC.sol";
import {MockTokenMessengerV2} from "../mocks/MockTokenMessengerV2.sol";

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

/**
 * @notice Stateful handler that drives the invariant harness.
 *
 *         Tracked quantities:
 *           - totalDeposited: sum of all USDC minted directly to the forwarder
 *           - totalBurned:    sum of all amount values recorded by the mock messenger
 */
contract ForwarderHandler is Test {
    CctpDepositForwarder public forwarder;
    MockUSDC public usdc;
    MockTokenMessengerV2 public messenger;

    uint256 public totalDeposited;
    uint256 public totalBurned;

    // Track all recorded burns for per-call invariant checks
    struct BurnRecord {
        uint256 amount;
        uint256 maxFee;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        bytes32 destinationCaller;
        bytes32 documentCommitment;
        bytes hookData;
    }
    BurnRecord[] public burnHistory;

    CctpDepositForwarder.ForwarderConfig internal _cfg;

    constructor(CctpDepositForwarder _forwarder, MockUSDC _usdc, MockTokenMessengerV2 _messenger) {
        forwarder = _forwarder;
        usdc = _usdc;
        messenger = _messenger;
        _cfg = _forwarder.config();
    }

    // -----------------------------------------------------------------------
    // Actions
    // -----------------------------------------------------------------------

    /// @notice Deposit random USDC to the forwarder (no-op if amount == 0).
    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 1e15);
        usdc.mint(address(forwarder), amount);
        totalDeposited += amount;
    }

    /// @notice Flush via fast path, from an arbitrary caller.
    function flushFast(address caller) external {
        uint256 bal = usdc.balanceOf(address(forwarder));
        if (bal == 0) return;

        uint256 before = messenger.callCount();
        vm.prank(caller);
        forwarder.flush(true);
        uint256 after_ = messenger.callCount();

        if (after_ > before) {
            MockTokenMessengerV2.BurnCall memory call = messenger.getCall(after_ - 1);
            totalBurned += call.amount;
            burnHistory.push(
                BurnRecord({
                    amount: call.amount,
                    maxFee: call.maxFee,
                    destinationDomain: call.destinationDomain,
                    mintRecipient: call.mintRecipient,
                    destinationCaller: call.destinationCaller,
                    documentCommitment: _extractCommitment(call.hookData),
                    hookData: call.hookData
                })
            );
        }
    }

    /// @notice Flush via standard path, from an arbitrary caller.
    function flushStandard(address caller) external {
        uint256 bal = usdc.balanceOf(address(forwarder));
        if (bal == 0) return;

        uint256 before = messenger.callCount();
        vm.prank(caller);
        forwarder.flush(false);
        uint256 after_ = messenger.callCount();

        if (after_ > before) {
            MockTokenMessengerV2.BurnCall memory call = messenger.getCall(after_ - 1);
            totalBurned += call.amount;
            burnHistory.push(
                BurnRecord({
                    amount: call.amount,
                    maxFee: call.maxFee,
                    destinationDomain: call.destinationDomain,
                    mintRecipient: call.mintRecipient,
                    destinationCaller: call.destinationCaller,
                    documentCommitment: _extractCommitment(call.hookData),
                    hookData: call.hookData
                })
            );
        }
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function burnCount() external view returns (uint256) {
        return burnHistory.length;
    }

    function getBurnRecord(uint256 i) external view returns (BurnRecord memory) {
        return burnHistory[i];
    }

    function cfg() external view returns (CctpDepositForwarder.ForwarderConfig memory) {
        return _cfg;
    }

    function _extractCommitment(bytes memory hookData) internal pure returns (bytes32 commitment) {
        if (hookData.length >= 64) {
            // abi.encode(bytes32, bytes32) — skip first 32 bytes (magic), read next 32
            assembly ("memory-safe") {
                commitment := mload(add(add(hookData, 0x20), 0x20))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Invariant test
// ---------------------------------------------------------------------------

/**
 * @title CctpDepositForwarderInvariantTest
 * @notice Handler-based invariant tests.
 *
 *   Invariant A: Forwarder allowance to messenger is always zero between calls.
 *   Invariant B: Every recorded burn targets the bound domain/recipient/caller/commitment.
 *   Invariant C: totalBurned + forwarder.balanceOf == totalDeposited.
 *   Invariant D: Every recorded maxFee is strictly < amount for that burn.
 *   Invariant E: Standard-path burns always have maxFee == 0.
 *   Invariant F: Standard-path burns always have minFinalityThreshold == 2000.
 */
contract CctpDepositForwarderInvariantTest is StdInvariant, Test {
    CctpDepositForwarder internal impl;
    MockUSDC internal usdc;
    MockTokenMessengerV2 internal messenger;
    CctpDepositForwarderFactory internal factory;
    CctpDepositForwarder internal forwarder;
    ForwarderHandler internal handler;

    uint32 constant DOMAIN = 1; // Avalanche
    bytes32 constant RECIPIENT = bytes32(uint256(0xBEEF_CAFE));
    bytes32 constant CALLER_B32 = bytes32(uint256(0xCAFE_BABE));
    bytes32 constant COMMITMENT = keccak256("invariant-doc");
    uint16 constant BPS = 50;

    function setUp() public {
        usdc = new MockUSDC();
        messenger = new MockTokenMessengerV2();
        impl = new CctpDepositForwarder();
        factory = new CctpDepositForwarderFactory(address(impl), address(usdc), address(messenger));

        address fwdAddr = factory.deploy(DOMAIN, RECIPIENT, CALLER_B32, BPS, COMMITMENT);
        forwarder = CctpDepositForwarder(fwdAddr);

        handler = new ForwarderHandler(forwarder, usdc, messenger);

        // Restrict fuzzer to handler only
        targetContract(address(handler));
    }

    // -----------------------------------------------------------------------
    // Invariant A: allowance always 0 between transactions
    // -----------------------------------------------------------------------

    function invariant_allowanceAlwaysZero() public view {
        uint256 allowance = usdc.allowance(address(forwarder), address(messenger));
        assertEq(allowance, 0, "Invariant A: non-zero allowance detected");
    }

    // -----------------------------------------------------------------------
    // Invariant B: every burn uses bound routing params and correct hookData
    // -----------------------------------------------------------------------

    function invariant_everyBurnHasBoundParams() public view {
        // Compared against the constants used at deploy time, NOT the forwarder's own decoded
        // config, so a decoding bug cannot make this invariant self-consistent.
        bytes memory expectedHook = abi.encode(keccak256("bufi.cctp-deposit-forwarder.v1"), COMMITMENT);
        uint256 n = messenger.callCount();
        assertEq(n, handler.burnCount(), "Invariant B: every messenger call came from a handler flush");
        for (uint256 i = 0; i < n; i++) {
            MockTokenMessengerV2.BurnCall memory c = messenger.getCall(i);
            assertEq(c.destinationDomain, DOMAIN, "Invariant B: domain");
            assertEq(c.mintRecipient, RECIPIENT, "Invariant B: recipient");
            assertEq(c.destinationCaller, CALLER_B32, "Invariant B: caller");
            assertEq(c.burnToken, address(usdc), "Invariant B: burn token");
            assertEq(c.caller, address(forwarder), "Invariant B: burner");
            assertEq(keccak256(c.hookData), keccak256(expectedHook), "Invariant B: hookData");
            assertTrue(c.minFinalityThreshold == 1000 || c.minFinalityThreshold == 2000, "Invariant B: threshold");
        }
    }

    // -----------------------------------------------------------------------
    // Invariant C: totalBurned + balance == totalDeposited
    // -----------------------------------------------------------------------

    function invariant_burnPlusBalanceEqualsDeposited() public view {
        uint256 balance = usdc.balanceOf(address(forwarder));
        assertEq(handler.totalBurned() + balance, handler.totalDeposited(), "Invariant C: accounting mismatch");
        assertEq(usdc.balanceOf(address(messenger)), handler.totalBurned(), "Invariant C: messenger received burns");
    }

    // -----------------------------------------------------------------------
    // Invariant D: every recorded maxFee < amount
    // -----------------------------------------------------------------------

    function invariant_maxFeeLtAmount() public view {
        uint256 n = handler.burnCount();
        for (uint256 i = 0; i < n; i++) {
            ForwarderHandler.BurnRecord memory r = handler.getBurnRecord(i);
            // amount > 0 always (NothingToFlush guard)
            assertLt(r.maxFee, r.amount, "Invariant D: maxFee >= amount");
        }
    }

    // -----------------------------------------------------------------------
    // Invariant E+F: cross-reference messenger's raw records for standard burns
    // -----------------------------------------------------------------------

    function invariant_standardBurns_correctFeeAndThreshold() public view {
        uint256 n = messenger.callCount();
        for (uint256 i = 0; i < n; i++) {
            MockTokenMessengerV2.BurnCall memory call = messenger.getCall(i);
            // Standard burns have threshold == 2000 and maxFee == 0
            if (call.minFinalityThreshold == forwarder.STANDARD_FINALITY_THRESHOLD()) {
                assertEq(call.maxFee, 0, "Invariant E: standard path maxFee != 0");
            }
            // Fast burns have threshold == 1000
            if (call.minFinalityThreshold == forwarder.FAST_FINALITY_THRESHOLD()) {
                assertLt(call.maxFee, call.amount, "Invariant F: fast path maxFee >= amount");
                uint256 expected = (call.amount * BPS + 9_999) / 10_000;
                if (expected >= call.amount) expected = call.amount - 1;
                assertEq(call.maxFee, expected, "Invariant F: fast fee formula");
            }
        }
    }
}
