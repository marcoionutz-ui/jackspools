// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title JackpotSwapHelper - Multi-Token Purchase Utility
 * @notice Enables 1-click JACKPOT purchases using any supported token on BSC.
 * @notice Designed for user simplicity and safety; performs automatic route and slippage management.
 * @dev Swaps: User Token → BNB → JACKPOT (via PancakeSwap)
 *
 * FEATURES:
 * - Supports 17 tokens (immutable list)
 * - Smart slippage adjustment (1–5% based on volatility)
 * - MEV protection via transaction deadlines
 * - Direct delivery to user wallet
 * - Frontend-ready with view functions and emitted events
 * - Emergency pause (renounceable owner)
 */

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    
    function getAmountsOut(uint amountIn, address[] calldata path) 
        external view returns (uint[] memory amounts);
    
    function WETH() external pure returns (address);
}

interface IJackpotToken {
    function balanceOf(address account) external view returns (uint256);
}

contract JackpotSwapHelper {
    
    // ============================================
    // IMMUTABLE STATE
    // ============================================
    
    IUniswapV2Router02 public immutable router;
    address public immutable jackpotToken;
    address public immutable WBNB;
    
    // ============================================
    // SUPPORTED TOKENS (HARDCODED - IMMUTABLE)
    // ============================================
    
    struct TokenInfo {
        address tokenAddress;
        string symbol;
        uint16 maxSlippageBps; // Basis points (100 = 1%)
        bool isStablecoin;
    }
    
    // 17 tokens total
    TokenInfo[17] private supportedTokens;
    mapping(address => bool) public isSupported;
    mapping(address => uint256) public tokenIndex; // For quick lookup
    
    // ============================================
    // OWNER & PAUSE (RENUNCEABLE)
    // ============================================
    
    address public owner;
    bool public paused;
    
    // ============================================
    // CONSTANTS
    // ============================================
    
    uint256 private constant BPS = 10000;
    uint256 private constant MAX_DEADLINE = 20 minutes;
    
    // ============================================
    // EVENTS
    // ============================================
    
    event TokenSwapped(
        address indexed user,
        address indexed inputToken,
        uint256 inputAmount,
        uint256 jackpotReceived,
        uint256 timestamp
    );
    
    event EmergencyPauseSet(bool paused);
    event OwnershipRenounced(address indexed previousOwner);
    
    // ============================================
    // MODIFIERS
    // ============================================
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    modifier whenNotPaused() {
        require(!paused, "Contract paused");
        _;
    }
    
    // ============================================
    // CONSTRUCTOR
    // ============================================
    
    constructor(
        address _router,
        address _jackpotToken
    ) {
        require(_router != address(0), "Zero router");
        require(_jackpotToken != address(0), "Zero token");
        
        router = IUniswapV2Router02(_router);
        jackpotToken = _jackpotToken;
        WBNB = router.WETH();
        owner = msg.sender;
        
        // Initialize 17 supported tokens (BSC Mainnet addresses)
        _initializeSupportedTokens();
    }
    
    /**
     * @notice Initialize the 17 supported tokens (hardcoded)
     * @dev Called once in constructor - immutable after deployment
     */
    function _initializeSupportedTokens() private {
        // STABLECOINS (4) - 1% slippage
        supportedTokens[0] = TokenInfo({
            tokenAddress: 0x55d398326f99059fF775485246999027B3197955,
            symbol: "USDT",
            maxSlippageBps: 100, // 1%
            isStablecoin: true
        });
        
        supportedTokens[1] = TokenInfo({
            tokenAddress: 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d,
            symbol: "USDC",
            maxSlippageBps: 100, // 1%
            isStablecoin: true
        });
        
        supportedTokens[2] = TokenInfo({
            tokenAddress: 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3,
            symbol: "DAI",
            maxSlippageBps: 100, // 1%
            isStablecoin: true
        });
        
        supportedTokens[3] = TokenInfo({
            tokenAddress: 0x40af3827F39D0EAcBF4A168f8D4ee67c121D11c9,
            symbol: "TUSD",
            maxSlippageBps: 100, // 1%
            isStablecoin: true
        });
        
        // MAJOR CRYPTO (8) - 3% slippage
        supportedTokens[4] = TokenInfo({
            tokenAddress: 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c,
            symbol: "BTCB",
            maxSlippageBps: 300, // 3%
            isStablecoin: false
        });
        
        supportedTokens[5] = TokenInfo({
            tokenAddress: 0x2170Ed0880ac9A755fd29B2688956BD959F933F8,
            symbol: "ETH",
            maxSlippageBps: 300, // 3%
            isStablecoin: false
        });
        
        supportedTokens[6] = TokenInfo({
            tokenAddress: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
            symbol: "WBNB",
            maxSlippageBps: 300, // 3%
            isStablecoin: false
        });
        
        supportedTokens[7] = TokenInfo({
            tokenAddress: 0x4338665CBB7B2485A8855A139b75D5e34AB0DB94,
            symbol: "LTC",
            maxSlippageBps: 300, // 3%
            isStablecoin: false
        });
        
        supportedTokens[8] = TokenInfo({
            tokenAddress: 0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE,
            symbol: "XRP",
            maxSlippageBps: 300, // 3%
            isStablecoin: false
        });
        
        supportedTokens[9] = TokenInfo({
            tokenAddress: 0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47,
            symbol: "ADA",
            maxSlippageBps: 300, // 3%
            isStablecoin: false
        });
        
        // VOLATILE (2) - 5% slippage
        supportedTokens[10] = TokenInfo({
            tokenAddress: 0xbA2aE424d960c26247Dd6c32edC70B295c744C43,
            symbol: "DOGE",
            maxSlippageBps: 500, // 5%
            isStablecoin: false
        });
        
        supportedTokens[11] = TokenInfo({
            tokenAddress: 0xCE7de646e7208a4Ef112cb6ed5038FA6cC6b12e3,
            symbol: "TRX",
            maxSlippageBps: 500, // 5%
            isStablecoin: false
        });
        
        // OTHER CHAINS (3) - 3% slippage
        supportedTokens[12] = TokenInfo({
            tokenAddress: 0xCC42724C6683B7E57334c4E856f4c9965ED682bD,
            symbol: "MATIC",
            maxSlippageBps: 300, // 3%
            isStablecoin: false
        });
        
        supportedTokens[13] = TokenInfo({
            tokenAddress: 0x1CE0c2827e2eF14D5C4f29a091d735A204794041,
            symbol: "AVAX",
            maxSlippageBps: 300, // 3%
            isStablecoin: false
        });
        
        supportedTokens[14] = TokenInfo({
            tokenAddress: 0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402,
            symbol: "DOT",
            maxSlippageBps: 300, // 3%
            isStablecoin: false
        });
        
        // DEFI/BSC NATIVE (2) - 3% slippage
        supportedTokens[15] = TokenInfo({
            tokenAddress: 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82,
            symbol: "CAKE",
            maxSlippageBps: 300, // 3%
            isStablecoin: false
        });
        
        supportedTokens[16] = TokenInfo({
            tokenAddress: 0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD,
            symbol: "LINK",
            maxSlippageBps: 300, // 3%
            isStablecoin: false
        });
        
        // Build mapping for quick lookups
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            isSupported[supportedTokens[i].tokenAddress] = true;
            tokenIndex[supportedTokens[i].tokenAddress] = i;
        }
    }
    
    // ============================================
    // MAIN FUNCTION - BUY WITH TOKEN
    // ============================================
    
    /**
     * @notice Buy JACKPOT tokens with any supported token
     * @param inputToken Address of token to swap from (must be in supported list)
     * @param inputAmount Amount of input token to swap
     * @param minJackpotOut Minimum JACKPOT tokens expected (slippage protection)
     * @param deadline Transaction deadline (MEV protection)
     * @return jackpotReceived Amount of JACKPOT tokens received
     */
    function buyWithToken(
        address inputToken,
        uint256 inputAmount,
        uint256 minJackpotOut,
        uint256 deadline
    ) external whenNotPaused returns (uint256 jackpotReceived) {
        require(isSupported[inputToken], "Token not supported");
        require(inputAmount > 0, "Zero amount");
        require(deadline >= block.timestamp, "Deadline passed");
        require(deadline <= block.timestamp + MAX_DEADLINE, "Deadline too far");
        
        // Transfer input token from user
        require(
            IERC20(inputToken).transferFrom(msg.sender, address(this), inputAmount),
            "Transfer failed"
        );
        
        // Get user's balance before
        uint256 jackpotBefore = IJackpotToken(jackpotToken).balanceOf(msg.sender);
        
        // Execute swap: Input Token → BNB → JACKPOT
        if (inputToken == WBNB) {
            // Direct: WBNB → JACKPOT (single swap)
            _swapWBNBForJackpot(inputAmount, minJackpotOut, deadline);
        } else {
            // Double swap: Token → WBNB → JACKPOT
            _swapTokenForJackpot(inputToken, inputAmount, minJackpotOut, deadline);
        }
        
        // Calculate received amount
        uint256 jackpotAfter = IJackpotToken(jackpotToken).balanceOf(msg.sender);
        jackpotReceived = jackpotAfter - jackpotBefore;
        
        require(jackpotReceived >= minJackpotOut, "Slippage too high");
        
        emit TokenSwapped(
            msg.sender,
            inputToken,
            inputAmount,
            jackpotReceived,
            block.timestamp
        );
        
        return jackpotReceived;
    }
    
    /**
     * @notice Swap WBNB directly for JACKPOT (single swap)
     */
    function _swapWBNBForJackpot(
        uint256 wbnbAmount,
        uint256 minJackpotOut,
        uint256 deadline
    ) private {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = jackpotToken;
        
        // Approve router
        require(IERC20(WBNB).approve(address(router), wbnbAmount), "WBNB approve failed");
        
        // Swap: WBNB → JACKPOT
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            wbnbAmount,
            minJackpotOut,
            path,
            msg.sender, // JACKPOT goes directly to user
            deadline
        );
    }
    
    /**
     * @notice Swap any token for JACKPOT (double swap via WBNB)
     */
    function _swapTokenForJackpot(
        address inputToken,
        uint256 inputAmount,
        uint256 minJackpotOut,
        uint256 deadline
    ) private {
        // Step 1: Input Token → WBNB
        address[] memory pathToBNB = new address[](2);
        pathToBNB[0] = inputToken;
        pathToBNB[1] = WBNB;
        
        // Approve router for input token
        require(IERC20(inputToken).approve(address(router), inputAmount), "Input token approve failed");
        
        // Get WBNB balance before
        uint256 wbnbBefore = IERC20(WBNB).balanceOf(address(this));
        
        // Swap: Token → WBNB
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            inputAmount,
            0, // Accept any amount (we check final JACKPOT amount)
            pathToBNB,
            address(this), // WBNB comes to contract
            deadline
        );
        
        // Calculate WBNB received
        uint256 wbnbReceived = IERC20(WBNB).balanceOf(address(this)) - wbnbBefore;
        require(wbnbReceived > 0, "No WBNB received");
        
        // Step 2: WBNB → JACKPOT
        address[] memory pathToJackpot = new address[](2);
        pathToJackpot[0] = WBNB;
        pathToJackpot[1] = jackpotToken;
        
        // Approve router for WBNB
        require(IERC20(WBNB).approve(address(router), wbnbReceived), "WBNB approve failed");
        
        // Swap: WBNB → JACKPOT
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            wbnbReceived,
            minJackpotOut,
            pathToJackpot,
            msg.sender, // JACKPOT goes directly to user
            deadline
        );
    }
    
    // ============================================
    // VIEW FUNCTIONS (FRONTEND HELPERS)
    // ============================================
    
    /**
     * @notice Get all supported tokens
     * @return tokens Array of TokenInfo structs
     */
    function getSupportedTokens() external view returns (TokenInfo[] memory tokens) {
        tokens = new TokenInfo[](supportedTokens.length);
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            tokens[i] = supportedTokens[i];
        }
        return tokens;
    }
    
    /**
     * @notice Get info for a specific token
     * @param token Token address to query
     * @return info TokenInfo struct
     */
    function getTokenInfo(address token) external view returns (TokenInfo memory info) {
        require(isSupported[token], "Token not supported");
        return supportedTokens[tokenIndex[token]];
    }
    
    /**
     * @notice Estimate JACKPOT output for given input
     * @param inputToken Token to swap from
     * @param inputAmount Amount of input token
     * @return estimatedJackpot Estimated JACKPOT tokens (before slippage)
     * @return minJackpotOut Minimum JACKPOT after slippage protection
     */
    function estimateJackpotOutput(
        address inputToken,
        uint256 inputAmount
    ) external view returns (
        uint256 estimatedJackpot,
        uint256 minJackpotOut
    ) {
        require(isSupported[inputToken], "Token not supported");
        require(inputAmount > 0, "Zero amount");
        
        uint256 estimatedOutput = 0;
        
        if (inputToken == WBNB) {
            // Direct swap: WBNB → JACKPOT
            estimatedOutput = _estimateOutput(WBNB, jackpotToken, inputAmount);
        } else {
            // Double swap: Token → WBNB → JACKPOT
            uint256 wbnbAmount = _estimateOutput(inputToken, WBNB, inputAmount);
            if (wbnbAmount > 0) {
                estimatedOutput = _estimateOutput(WBNB, jackpotToken, wbnbAmount);
            }
        }
        
        // Apply slippage protection
        TokenInfo memory info = supportedTokens[tokenIndex[inputToken]];
        uint256 slippageBps = info.maxSlippageBps;
        
        estimatedJackpot = estimatedOutput;
        
        // CRITICAL: Account for 10% buy tax in minOut calculation
        // User receives 90% of estimated due to TOTAL_BUY_TAX_BPS = 1000
        uint256 afterTax = (estimatedOutput * 9000) / BPS; // 90% after 10% tax
        minJackpotOut = (afterTax * (BPS - slippageBps)) / BPS;
        
        return (estimatedJackpot, minJackpotOut);
    }
    
    /**
     * @notice Estimate output for a swap
     */
    function _estimateOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) private view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        
        try router.getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
            return amounts[1];
        } catch {
            return 0;
        }
    }
    
    /**
     * @notice Check if a token is supported
     * @param token Token address to check
     * @return supported True if token is in whitelist
     */
    function isTokenSupported(address token) external view returns (bool supported) {
        return isSupported[token];
    }
    
    /**
     * @notice Get total number of supported tokens
     */
    function getSupportedTokenCount() external pure returns (uint256) {
        return 17;
    }
    
    // ============================================
    // OWNER FUNCTIONS (EMERGENCY ONLY)
    // ============================================
    
    /**
     * @notice Emergency pause (owner only)
     * @dev Use only if critical bug found before renouncing ownership
     */
    function setEmergencyPause(bool _paused) external onlyOwner {
        paused = _paused;
        emit EmergencyPauseSet(_paused);
    }
    
    /**
     * @notice Renounce ownership (makes contract immutable)
     * @dev After this, no one can pause the contract
     */
    function renounceOwnership() external onlyOwner {
        emit OwnershipRenounced(owner);
        owner = address(0);
    }
    
    /**
     * @notice Recover stuck tokens (emergency only, before renounce)
     * @dev Should never be needed if contract works correctly
     */
    function recoverStuckTokens(address token, uint256 amount) external onlyOwner {
        require(token != jackpotToken, "Cannot recover JACKPOT");
        require(IERC20(token).approve(msg.sender, amount), "Approve failed");
		require(IERC20(token).transferFrom(address(this), msg.sender, amount), "Recovery failed");
    }
    
    // ============================================
    // FALLBACK
    // ============================================
    
    /**
     * @notice Reject direct BNB transfers
     */
    receive() external payable {
        revert("Use buyWithToken()");
    }
}
