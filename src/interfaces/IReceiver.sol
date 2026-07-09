// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IReceiver — minimal Chainlink CRE report receiver interface.
/// @notice KeystoneForwarder checks ERC-165 support for this interface before
///         delivering a report through {onReport}.
interface IReceiver is IERC165 {
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
