// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/libraries/FunctionsRequest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OracleLib, AggregatorV3Interface} from "../libraries/OracleLib.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {OracleLib} from "../libraries/OracleLib.sol";

contract dTSLA is ConfirmedOwner, FunctionsClient, ERC20 {
    using FunctionsRequest for FunctionsRequest.Request;
    using Strings for uint256;
    using OracleLib for AggregatorV3Interface;

    error dTSLA__NotEnoughCollateral();
    error dTSLA__DoesntMeetMinimumWithdrawAmount();
    error dTSLA__transferFailed();

    address constant SEPOLIA_FUNCTIONS_ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    string private s_mintSourceCode;
    string private s_redeemSourceCode;

    uint64 immutable i_subId;
    uint32 constant GAS_LIMIT = 300_000;
    bytes32 constant DON_ID = hex"66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000";
    uint256 constant PRECISION = 1e18;
    address constant SEPOLIA_TSLA_PRICE_FEED = 0xc59E3633BAAC79493d908e63626716e204A45EdF; // this accually LINK/USD price feed because there is no TSLA price feed on sepolia
    uint256 constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 constant COLLECTAREL_RATIO = 200;
    uint256 constant COLLECTAREL_PRECISION = 100;
    uint256 constant MINIMUM_WITHDRAW_AMOUNT = 100e18;
    address constant SEPOLIA_USDC_PRICE_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E; // this accually LINK/USD price feed because there is no TSLA price feed on sepolia
    address constant SEPOLIA_USDC = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;

    enum MintOrRedeem {
        mint,
        redeem
    }

    struct dTslaRequest {
        uint256 amountOfToken;
        address requester;
        MintOrRedeem mintOrRedeem;
    }

    mapping(bytes32 requestId => dTslaRequest request) private s_requestToRequest;
    mapping(address user => uint256 pendingWithdrawAmount) private s_userToWithdrawAmount;
    uint256 private s_portfolioBalance;
    // sent an http request to:
    // 1- see how much tesla is bought
    // 2- if enough TSLA is in the alpaca account,
    // mint dTSLA

    function sendMintRequest(uint256 amount) external onlyOwner returns (bytes32) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_mintSourceCode); // Initialize the request with JS code

        bytes32 requestId = _sendRequest(req.encodeCBOR(), i_subId, GAS_LIMIT, DON_ID);
        s_requestToRequest[requestId] = dTslaRequest(amount, msg.sender, MintOrRedeem.mint);
        return requestId;
    }

    constructor(string memory mintSourceCode, string memory redeemSourceCode, uint64 subId)
        ConfirmedOwner(msg.sender)
        FunctionsClient(SEPOLIA_FUNCTIONS_ROUTER)
        ERC20("dTsla", "dTSLA")
    {
        s_mintSourceCode = mintSourceCode;
        s_redeemSourceCode = redeemSourceCode;
        i_subId = subId;
    }
    // Return the amount of TSLA in USD in brokerage
    // if we have enough TSLA token mint dTSLA

    function _mintFulFillRequest(bytes32 requestId, bytes memory response) internal {
        uint256 amountOfTokensToMint = s_requestToRequest[requestId].amountOfToken;
        s_portfolioBalance = uint256(bytes32(response));
        if (_getCollateralRatioAdjustedTotalBalance(amountOfTokensToMint) > s_portfolioBalance) {
            revert dTSLA__NotEnoughCollateral();
        }
        if (amountOfTokensToMint != 0) {
            _mint(s_requestToRequest[requestId].requester, amountOfTokensToMint);
        }
    }
    // @notice User sends a request to sell TSLA for USDC (redemptionToken)
    // This will, have the chainlink function call our alpaca
    // and do following:
    // 1- Sell TSLA on the brokerage
    // 2- buy USDC on the brokerage
    // 3- send USDC to this contract to user withdraw

    function sendRedeemRequest(uint256 amountdTsla) external {
        uint256 amountInTslaInUsdc = getUsdcValueOfUsd(getUsdcValueOfTsla(amountdTsla));
        if (amountInTslaInUsdc < MINIMUM_WITHDRAW_AMOUNT) {
            revert dTSLA__DoesntMeetMinimumWithdrawAmount();
        }

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_redeemSourceCode); // Initialize the request with JS code

        string[] memory args = new string[](2);
        args[0] = amountdTsla.toString();
        args[1] = amountInTslaInUsdc.toString();
        req.setArgs(args);
        bytes32 requestId = _sendRequest(req.encodeCBOR(), i_subId, GAS_LIMIT, DON_ID);
        s_requestToRequest[requestId] = dTslaRequest(amountdTsla, msg.sender, MintOrRedeem.redeem);

        _burn(msg.sender, amountdTsla);
    }

    function _redeemFulFillRequest(bytes32 requestId, bytes memory response) internal {
        uint256 usdcAmount = uint256(bytes32(response));
        if (usdcAmount == 0) {
            uint256 amountOfdTslaBurned = s_requestToRequest[requestId].amountOfToken;
            _mint(s_requestToRequest[requestId].requester, amountOfdTslaBurned);
            return;
        }

        s_userToWithdrawAmount[s_requestToRequest[requestId].requester] += usdcAmount;
    }

    function withdraw() external {
        uint256 amountToWithdrawAmount = s_userToWithdrawAmount[msg.sender];
        s_userToWithdrawAmount[msg.sender] = 0;

        bool success = ERC20(SEPOLIA_USDC).transfer(msg.sender, amountToWithdrawAmount);
        if (!success) {
            revert dTSLA__transferFailed();
        }
    }

    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        if (s_requestToRequest[requestId].mintOrRedeem == MintOrRedeem.mint) {
            _mintFulFillRequest(requestId, response);
        } else {
            _redeemFulFillRequest(requestId, response);
        }
    }

    function _getCollateralRatioAdjustedTotalBalance(uint256 amountOfTokenToMint) internal view returns (uint256) {
        uint256 calculatedNewTotalValue = _getCalculatedNewTokenValue(amountOfTokenToMint);
        return calculatedNewTotalValue * COLLECTAREL_RATIO / COLLECTAREL_PRECISION;
    }
    // The new expected total value in USD of all the dTsla tokens combined

    function _getCalculatedNewTokenValue(uint256 addedNumberOfTokens) internal view returns (uint256) {
        // 10 dtsla tokens + 5 dtsla tokens = 15 dtsla tokens * tsla price(100) = 1500
        return ((totalSupply() + addedNumberOfTokens) * getTslaPrice()) / PRECISION;
    }

    function getUsdcValueOfTsla(uint256 tslaAmount) public view returns (uint256) {
        return (tslaAmount * getTslaPrice()) / PRECISION;
    }

    function getTslaPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(SEPOLIA_TSLA_PRICE_FEED);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return uint256(price) * ADDITIONAL_FEED_PRECISION;
    }

    function getUsdcPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(SEPOLIA_USDC_PRICE_FEED);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return uint256(price) * ADDITIONAL_FEED_PRECISION;
    }
    /* 
     * Pass the USD amount with 18 decimals (WAD)
     * Return the redemptionCoin amount with 18 decimals (WAD)
     * 
     * @param usdAmount - the amount of USD to convert to USDC in WAD
     * @return the amount of redemptionCoin with 18 decimals (WAD)
     */

    function getUsdcValueOfUsd(uint256 usdAmount) public view returns (uint256) {
        return (usdAmount * getUsdcPrice()) / PRECISION;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW AND PURE
    //////////////////////////////////////////////////////////////*/
    function getPortfolioBalance() public view returns (uint256) {
        return s_portfolioBalance;
    }

    function getTotalUsdValue() public view returns (uint256) {
        return (totalSupply() * getTslaPrice()) / PRECISION;
    }

    function getCalculatedNewTotalValue(uint256 addedNumberOfTsla) public view returns (uint256) {
        return ((totalSupply() + addedNumberOfTsla) * getTslaPrice()) / PRECISION;
    }

    function getRequest(bytes32 requestId) public view returns (dTslaRequest memory) {
        return s_requestToRequest[requestId];
    }

    function getWithdrawalAmount(address user) public view returns (uint256) {
        return s_userToWithdrawAmount[user];
    }
}
