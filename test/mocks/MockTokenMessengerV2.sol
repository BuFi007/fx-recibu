// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenMessengerV2} from "../../src/interfaces/ITokenMessengerV2.sol";

/**
 * @title MockTokenMessengerV2
 * @notice Test double for Circle's TokenMessengerV2.
 *
 *         Behaviour modes (toggle with setters):
 *          - Normal (default): pulls `amount` via transferFrom, records the call.
 *          - Revert mode: always reverts depositForBurnWithHook.
 *          - Pull-less mode: pulls `amount - 1` (simulates under-pull) so the forwarder's
 *            AllowanceNotConsumed post-condition fires.
 */
interface IFlushable {
    function flush(bool fast) external returns (uint256, uint256);
}

contract MockTokenMessengerV2 is ITokenMessengerV2 {
    // -------------------------------------------------------------------------
    // Recorded call struct
    // -------------------------------------------------------------------------

    struct BurnCall {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        bytes hookData;
        address caller;
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    BurnCall[] public calls;

    bool public shouldRevert;
    bool public pullLess; // pull amount-1 instead of amount (triggers AllowanceNotConsumed)
    bool public refundOne; // pull amount, then send 1 unit back (triggers BalanceNotBurned)
    bool public reenter; // call flush() on the caller again from inside the burn

    // -------------------------------------------------------------------------
    // Control
    // -------------------------------------------------------------------------

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function setPullLess(bool _pullLess) external {
        pullLess = _pullLess;
    }

    function setRefundOne(bool v) external {
        refundOne = v;
    }

    function setReenter(bool v) external {
        reenter = v;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function getCall(uint256 i) external view returns (BurnCall memory) {
        return calls[i];
    }

    function reset() external {
        delete calls;
        shouldRevert = false;
        pullLess = false;
        refundOne = false;
        reenter = false;
    }

    // -------------------------------------------------------------------------
    // ITokenMessengerV2
    // -------------------------------------------------------------------------

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external override {
        if (shouldRevert) revert("MockTokenMessengerV2: revert");

        uint256 pullAmount = pullLess ? amount - 1 : amount;
        // Mimics the real messenger: pull tokens from caller.
        IERC20(burnToken).transferFrom(msg.sender, address(this), pullAmount);
        if (refundOne) IERC20(burnToken).transfer(msg.sender, 1);
        if (reenter) IFlushable(msg.sender).flush(true);

        calls.push(
            BurnCall({
                amount: amount,
                destinationDomain: destinationDomain,
                mintRecipient: mintRecipient,
                burnToken: burnToken,
                destinationCaller: destinationCaller,
                maxFee: maxFee,
                minFinalityThreshold: minFinalityThreshold,
                hookData: hookData,
                caller: msg.sender
            })
        );
    }
}
