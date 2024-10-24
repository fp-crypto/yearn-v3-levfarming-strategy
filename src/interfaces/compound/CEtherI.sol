pragma solidity >=0.5.16;

import "./CTokenI.sol";

interface CEtherI is CTokenI {
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    function redeem(uint256 redeemTokens) external returns (uint256);

    function liquidateBorrow(address borrower, CTokenI cTokenCollateral) external payable;

    function borrow(uint256 borrowAmount) external returns (uint);

    function mint() external payable;
    function repayBorrow() external payable;
}
