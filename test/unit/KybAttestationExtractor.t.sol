// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KybAttestationExtractor, IKybReportReceiver} from "../../src/identity/KybAttestationExtractor.sol";

contract MockKybReportReceiver is IKybReportReceiver {
    bytes public lastMetadata;
    bytes public lastReport;

    function onReport(bytes calldata metadata, bytes calldata report) external {
        lastMetadata = metadata;
        lastReport = report;
    }
}

contract KybAttestationExtractorTest is Test {
    uint64 internal constant CHAIN = 14767482510784806043;
    address internal owner = makeAddr("owner");
    address internal forwarder = makeAddr("forwarder");
    address internal stranger = makeAddr("stranger");
    MockKybReportReceiver internal target;
    KybAttestationExtractor internal extractor;

    function setUp() public {
        target = new MockKybReportReceiver();
        extractor = new KybAttestationExtractor(owner, forwarder, CHAIN, target);
    }

    function test_forwardsOnlyFromConfiguredForwarder() public {
        bytes memory metadata = abi.encode(bytes32("workflow"), CHAIN, bytes32("op"), uint64(block.timestamp + 1 days));
        bytes memory report = abi.encode(uint8(1), uint256(uint160(bytes20("team"))), true, uint64(block.timestamp + 1 days), uint64(1), bytes32("op"), bytes32("workflow"), CHAIN, uint64(block.timestamp + 1 days));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KybAttestationExtractor.NotForwarder.selector, stranger));
        extractor.onReport(metadata, report);

        vm.prank(forwarder);
        extractor.onReport(metadata, report);
        assertEq(target.lastMetadata(), metadata);
        assertEq(target.lastReport(), report);
    }

    function test_workflowBindingFailsClosed() public {
        vm.prank(owner);
        extractor.setExpectedWorkflowId(bytes32("expected"));
        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                KybAttestationExtractor.UnexpectedWorkflowId.selector,
                bytes32("wrong"),
                bytes32("expected")
            )
        );
        extractor.onReport(abi.encode(bytes32("wrong")), bytes("report"));
    }
}
